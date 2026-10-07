package kvist

import "core:strings"

// Both slices borrow from ty. Match the outer parameter list rather than an
// inner callback's closing parenthesis or return arrow.
proc_type_parts :: proc(ty: string) -> (params, result: string, ok: bool) {
    if !strings.has_prefix(ty, "proc(") {
        return "", "", false
    }
    depth := 1
    for idx := len("proc("); idx < len(ty); idx += 1 {
        switch ty[idx] {
        case '(':
            depth += 1
        case ')':
            depth -= 1
            if depth != 0 {
                continue
            }
            tail := strings.trim_space(ty[idx+1:])
            if tail == "" {
                return ty[len("proc("):idx], "", true
            }
            if !strings.has_prefix(tail, "->") {
                return "", "", false
            }
            result = strings.trim_space(tail[len("->"):])
            return ty[len("proc("):idx], result, result != ""
        }
    }
    return "", "", false
}

proc_type_single_return_type :: proc(ty: string) -> (string, bool) {
    _, result, ok := proc_type_parts(ty)
    return result, ok && result != ""
}

// The array owns its storage; each type string borrows from ty. Named returns
// keep their order so cleanup and type inference use the same result indexes.
proc_type_return_types :: proc(ty: string) -> (types: [dynamic]string, ok: bool) {
    _, result, parsed := proc_type_parts(ty)
    if !parsed {
        return types, false
    }
    if result == "" {
        return types, true
    }
    if !strings.has_prefix(result, "(") {
        append(&types, result)
        return types, true
    }
    if !strings.has_suffix(result, ")") {
        return types, false
    }
    parts := split_top_level_commas(result[1:len(result)-1])
    defer delete(parts)
    for part in parts {
        colon := top_level_colon_index(part)
        result_type := strings.trim_space(part[colon+1:])
        if result_type == "" {
            delete(types)
            return nil, false
        }
        append(&types, result_type)
    }
    return types, true
}

proc_value_call_type :: proc(e: ^Emitter, form: CST_Form) -> (string, bool) {
    if e == nil || form.kind != .List || len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return "", false
    }
    ty, known := known_form_type(e, form.items[0])
    if known {
        return ty, type_text_is_proc(ty)
    }
    // Named declarations keep their richer ownership and generic contracts.
    // Procedure values may instead be global or inferred from an initializer.
    if _, _, named := resolve_proc_call_decl(e, form.items[0].text); named {
        return "", false
    }
    ty, known = obvious_form_type(e, form.items[0])
    return ty, known && type_text_is_proc(ty)
}

procedure_symbol_value_type :: proc(e: ^Emitter, name: string, depth: int = 0) -> (string, bool) {
    if e == nil || depth > 16 {
        return "", false
    }
    if ty, known := lookup_local_type(e, name); known {
        return ty, type_text_is_proc(ty)
    }
    if _, decl, known := resolve_proc_call_decl(e, name); known && decl != nil {
        return proc_type_with_capture_params_text(0, decl.params[:], decl.returns), true
    }
    ensure_emitter_indexes(e)
    if idx, known := e.const_indices[name]; known {
        decl := &e.decls[idx].const_decl
        if decl.has_ty {
            return decl.ty, type_text_is_proc(decl.ty)
        }
        if decl.value.kind == .Symbol {
            mapped := map_name(decl.value.text)
            defer delete(mapped)
            return procedure_symbol_value_type(e, mapped, depth+1)
        }
        if decl.value.kind == .List && len(decl.value.items) > 0 && is_symbol(decl.value.items[0], "fn") {
            parsed, _, valid := parse_proc_literal_form(decl.value)
            if valid { return proc_literal_type_text(parsed), true }
        }
    }
    for &decl in e.decls {
        if decl.kind == .Var && decl.var_decl.name == name {
            if decl.var_decl.has_ty {
                return decl.var_decl.ty, type_text_is_proc(decl.var_decl.ty)
            }
            if decl.var_decl.value.kind == .Symbol {
                mapped := map_name(decl.var_decl.value.text)
                defer delete(mapped)
                return procedure_symbol_value_type(e, mapped, depth+1)
            }
            if decl.var_decl.value.kind == .List && len(decl.var_decl.value.items) > 0 && is_symbol(decl.var_decl.value.items[0], "fn") {
                parsed, _, valid := parse_proc_literal_form(decl.var_decl.value)
                if valid { return proc_literal_type_text(parsed), true }
            }
        }
    }
    return "", false
}

// Data and structs containing Data normalize borrowed body values at their
// return boundary. Their public result is owned even when body provenance is
// borrowed or unknown, including calls through procedure-valued fields.
call_returns_owned_data_lifecycle_type :: proc(
    e: ^Emitter,
    form: CST_Form,
    ty: string,
) -> bool {
    if !type_text_has_data_lifecycle(e, ty) || form.kind != .List ||
       len(form.items) == 0 || form.items[0].kind != .Symbol {
        return false
    }
    if proc_ty, known := proc_value_call_type(e, form); known {
        types, parsed := proc_type_return_types(proc_ty)
        defer delete(types)
        return parsed && len(types) == 1 && types[0] == ty
    }
    if _, decl, resolved := resolve_proc_call_decl(e, form.items[0].text);
       resolved && decl != nil {
        if decl.returns.kind == .Single {
            result_type, known := proc_decl_obvious_call_return_type(e, decl, form.items[1:])
            return known && result_type == ty
        }
        return decl.returns.kind == .Named && len(decl.returns.named) == 1 &&
               decl.returns.named[0].ty == ty
    }
    call_name := map_name(form.items[0].text)
    defer delete(call_name)
    if result_type, known := overload_obvious_call_return_type(e, call_name, form.items[1:]); known {
        defer delete(result_type)
        return result_type == ty
    }
    return false
}
