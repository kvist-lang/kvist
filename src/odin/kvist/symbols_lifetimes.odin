package kvist

import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"
import "base:runtime"

procedure_ownership_contract_detail :: proc(
    contract: ^Procedure_Ownership_Contract,
) -> string {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    first := true
    if contract.result_flow == .Owned {
        strings.write_string(&builder, "lifetime=result-owned")
        first = false
    } else if contract.result_flow == .Borrowed {
        strings.write_string(&builder, "lifetime=result-borrowed")
        first = false
    }
    for field_index in contract.owned_result_fields {
        if !first {
            strings.write_byte(&builder, ';')
        }
        fmt.sbprintf(&builder, "result-field-owned=%d", field_index)
        first = false
    }
    if contract.result_fields_uncertain {
        if !first {
            strings.write_byte(&builder, ';')
        }
        strings.write_string(&builder, "result-fields=uncertain")
        first = false
    }
    for idx in contract.consumed_parameters {
        if !first {
            strings.write_byte(&builder, ';')
        }
        fmt.sbprintf(&builder, "consumes=%d", idx)
        first = false
    }
    return strings.to_string(builder)
}

symbols_proc_lifetime_detail :: proc(decl: ^Proc_Decl) -> string {
    contract := procedure_ownership_contract(decl)
    defer procedure_ownership_contract_delete(&contract)
    return procedure_ownership_contract_detail(&contract)
}

lifetime_type_is_relevant :: proc(ty: string) -> bool {
    text := strings.trim_space(ty)
    return text == "Data" ||
           text == "string" ||
           text == "cstring" ||
           text == "rawptr" ||
           type_text_is_slice_or_fixed_array(text) ||
           type_text_is_dynamic_array(text) ||
           type_text_is_map(text) ||
           strings.has_prefix(text, "^")
}

lifetimes_write_proc :: proc(
    builder: ^strings.Builder,
    name: string,
    decl: ^Proc_Decl,
    e: ^Emitter = nil,
) {
    contract := procedure_ownership_contract(decl, e)
    defer procedure_ownership_contract_delete(&contract)
    relevant := procedure_ownership_contract_has_facts(&contract)
    if !relevant {
        for param in decl.params {
            if lifetime_type_is_relevant(param.ty) {
                relevant = true
                break
            }
        }
    }
    if !relevant && decl.returns.kind == .Single {
        relevant = lifetime_type_is_relevant(decl.returns.single_ty)
    }
    if !relevant {
        return
    }

    display_name, display_allocated := strings.replace_all(name, "_", "-")
    if display_allocated {
        defer delete(display_name)
    }
    signature := symbols_proc_signature(display_name, decl^)
    defer delete(signature)
    fmt.sbprintf(builder, "%s\n  %s\n", display_name, signature)

    borrowed_result := contract.result_flow == .Borrowed
    owned_result := contract.result_flow == .Owned
    if decl.returns.kind == .Single && lifetime_type_is_relevant(decl.returns.single_ty) {
        if decl.returns.single_ty == "Data" && borrowed_result {
            strings.write_string(builder, "  result: caller-owned Data reference; the compiler retains the borrowed source at the return boundary\n")
        } else if decl.returns.single_ty == "Data" && owned_result {
            strings.write_string(builder, "  result: caller-owned Data reference; every inferred return path already produces a new reference\n")
        } else if owned_result {
            strings.write_string(builder, "  result: owned; every inferred return path produces a new value\n")
        } else if borrowed_result {
            strings.write_string(builder, "  result: borrowed; the return aliases an input or a known foreign view\n")
        } else {
            strings.write_string(builder, "  result: explicit/unknown; Kvist does not infer transfer at this boundary\n")
        }
    }

    if len(contract.owned_result_fields) > 0 {
        return_struct, ok_struct := proc_single_struct_return(e, decl)
        for field_index in contract.owned_result_fields {
            if ok_struct && field_index >= 0 &&
               field_index < len(return_struct.fields) {
                fmt.sbprintf(
                    builder,
                    "  result field %s: owned; ownership transfers to the caller and automatic scoped cleanup is available\n",
                    return_struct.fields[field_index].name,
                )
            } else {
                fmt.sbprintf(
                    builder,
                    "  result field #%d: owned; ownership transfers to the caller and automatic scoped cleanup is available\n",
                    field_index,
                )
            }
        }
    }
    if contract.result_fields_uncertain {
        strings.write_string(
            builder,
            "  result fields: uncertain across returns or mutations; automatic caller cleanup is not inserted\n",
        )
    }

    for param, idx in decl.params {
        if !lifetime_type_is_relevant(param.ty) {
            continue
        }
        if procedure_ownership_contract_consumes(&contract, idx) {
            fmt.sbprintf(
                builder,
                "  %s: consumed; the body explicitly deletes it or transfers it through an owned result\n",
                param.name,
            )
        } else {
            fmt.sbprintf(
                builder,
                "  %s: borrowed; no consuming path was inferred\n",
                param.name,
            )
        }
    }
    strings.write_byte(builder, '\n')
}

lifetimes_source :: proc(source: string) -> (output: string, err: Compile_Error, ok: bool) {
    result_allocator := context.allocator
    old_allocator := context.allocator
    temp_scope := runtime.default_temp_allocator_temp_begin()
    defer runtime.default_temp_allocator_temp_end(temp_scope)
    context.allocator = context.temp_allocator
    defer context.allocator = old_allocator

    forms, err_forms, ok_forms := read_kvist_top_forms(source)
    if !ok_forms {
        return "", clone_compile_error(err_forms, result_allocator), false
    }
    defer delete_borrowed_cst_top_form_slice(&forms)

    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    strings.write_string(
        &builder,
        "Inferred lifetime boundaries (no source annotations):\n\n",
    )
    for top in forms {
        form := top.form
        if form.kind != .List ||
           len(form.items) < 3 ||
           form.items[0].kind != .Symbol ||
           (form.items[0].text != "defn" && form.items[0].text != "defn-") ||
           form.items[1].kind != .Symbol {
            continue
        }
        proc_form := form
        if len(form.items) > 3 && form.items[2].kind == .String {
            items: [dynamic]CST_Form
            append(&items, form.items[0], form.items[1])
            for item in form.items[3:] {
                append(&items, item)
            }
            proc_form = CST_Form{kind = .List, items = items, span = form.span}
        }
        decl, err_decl, ok_decl := parse_proc_decl(proc_form)
        if !ok_decl {
            return "", clone_compile_error(err_decl, result_allocator), false
        }
        lifetimes_write_proc(&builder, form.items[1].text, &decl)
    }
    return strings.clone(strings.to_string(builder), result_allocator), {}, true
}

lifetimes_path :: proc(path: string) -> (output: string, err: Compile_Error, ok: bool) {
    result_allocator := context.allocator
    old_allocator := context.allocator
    temp_scope := runtime.default_temp_allocator_temp_begin()
    defer runtime.default_temp_allocator_temp_end(temp_scope)
    context.allocator = context.temp_allocator
    defer context.allocator = old_allocator

    program, err_program, ok_program := load_path_program(path)
    if !ok_program {
        return "", clone_compile_error(err_program, result_allocator), false
    }
    lowered, err_lower, ok_lower := lower_program(program)
    if !ok_lower {
        return "", clone_compile_error(err_lower, result_allocator), false
    }

    import_cache := Emitter_Import_Cache{}
    emitter_import_cache_init(&import_cache)
    defer emitter_import_cache_delete(&import_cache)
    emitter := Emitter{
        decls = lowered.decls[:],
        import_cache = &import_cache,
    }
    for decl in lowered.decls {
        if decl.kind == .Struct {
            append(&emitter.structs, decl.struct_decl)
        }
        if decl.kind == .Union {
            append(&emitter.unions, decl.union_decl)
        }
    }
    infer_decoded_struct_lifetimes(&emitter)
    infer_proc_lifetime_facts(&emitter)

    canonical_path, canonical_err := os.get_absolute_path(path, context.allocator)
    if canonical_err != nil {
        canonical_path = path
    }
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    strings.write_string(
        &builder,
        "Inferred lifetime boundaries (no source annotations):\n\n",
    )
    for &decl in emitter.decls {
        if decl.kind != .Proc {
            continue
        }
        if decl.source_path != "" {
            decl_path, decl_path_err := os.get_absolute_path(decl.source_path, context.allocator)
            same_file := decl_path_err == nil && decl_path == canonical_path
            if decl_path_err == nil {
                delete(decl_path)
            }
            if !same_file {
                continue
            }
        }
        lifetimes_write_proc(
            &builder,
            decl.proc_decl.name,
            &decl.proc_decl,
            &emitter,
        )
    }
    return strings.clone(strings.to_string(builder), result_allocator), {}, true
}
