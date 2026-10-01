package kvist

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

result_has_owned_aggregate_fields :: proc(
    e: ^Emitter,
    form: CST_Form,
    result_index, result_count: int,
) -> bool {
    fields := proc_call_owned_result_fields_at(
        e,
        form,
        result_index,
        result_count,
    )
    defer delete_struct_field_slice(&fields)
    return len(fields) > 0
}

result_has_owned_union_variant :: proc(
    e: ^Emitter,
    form: CST_Form,
    result_index, result_count: int,
) -> bool {
    union_type, variant_type, ok := proc_call_owned_union_result_variant_at(
        e,
        form,
        result_index,
        result_count,
    )
    defer delete(union_type)
    defer delete(variant_type)
    return ok
}

form_has_owned_aggregate_result_fields :: proc(
    e: ^Emitter,
    form: CST_Form,
) -> bool {
    result_count, known_count := result_lifecycle_call_result_count(e, form)
    if !known_count {
        result_count = 1
    }
    for result_index in 0..<result_count {
        if result_has_owned_aggregate_fields(
            e,
            form,
            result_index,
            result_count,
        ) {
            return true
        }
    }
    return false
}

form_has_owned_union_result_variant :: proc(
    e: ^Emitter,
    form: CST_Form,
) -> bool {
    result_count, known_count := result_lifecycle_call_result_count(e, form)
    if !known_count {
        result_count = 1
    }
    for result_index in 0..<result_count {
        if result_has_owned_union_variant(
            e,
            form,
            result_index,
            result_count,
        ) {
            return true
        }
    }
    return false
}

emit_automatic_native_delete_value :: proc(
    e: ^Emitter,
    ty, value: string,
    depth := 0,
) {
    if depth > 16 {
        return
    }
    if type_supports_automatic_native_delete(ty) {
        emit_line(e, ownership_destroy_value_text(e, ty, value))
        return
    }
    struct_decl, ok_struct := find_struct_decl(e, strings.trim_space(ty))
    if !ok_struct || type_text_has_managed_lifecycle(e, struct_decl.name) {
        return
    }
    for field in struct_decl.fields {
        emit_automatic_native_delete_value(
            e,
            field.ty,
            fmt.tprintf("%s.%s", value, field.name),
            depth+1,
        )
    }
}

emit_owned_union_result_cleanup :: proc(
    e: ^Emitter,
    form: CST_Form,
    result_index, result_count: int,
    value_name: string,
    deferred: bool,
) -> bool {
    union_type, variant_type, ok := proc_call_owned_union_result_variant_at(
        e,
        form,
        result_index,
        result_count,
    )
    defer delete(union_type)
    defer delete(variant_type)
    if !ok || value_name == "" {
        return false
    }
    if deferred {
        emit_line(e, "defer {")
        e.indent += 1
    }
    payload_name := thread_temp_name(e)
    defer delete(payload_name)
    emit_line(e, fmt.tprintf(
        "#partial switch %s in %s {{",
        payload_name,
        value_name,
    ))
    e.indent += 1
    emit_line(e, fmt.tprintf("case %s:", variant_type))
    e.indent += 1
    emit_automatic_native_delete_value(e, variant_type, payload_name)
    e.indent -= 1
    e.indent -= 1
    emit_line(e, "}")
    if deferred {
        e.indent -= 1
        emit_line(e, "}")
    }
    return true
}

emit_owned_union_result_guarded_cleanup :: proc(
    e: ^Emitter,
    form: CST_Form,
    result_index, result_count: int,
    value_name, owner_flag: string,
) -> bool {
    union_type, variant_type, ok := proc_call_owned_union_result_variant_at(
        e,
        form,
        result_index,
        result_count,
    )
    defer delete(union_type)
    defer delete(variant_type)
    if !ok || value_name == "" || owner_flag == "" {
        return false
    }
    emit_line(e, fmt.tprintf(
        "defer (proc(kvist_place: ^%s, kvist_owner: ^bool) {{",
        union_type,
    ))
    e.indent += 1
    emit_line(e, "if kvist_owner^ {")
    e.indent += 1
    payload_name := thread_temp_name(e)
    defer delete(payload_name)
    emit_line(e, fmt.tprintf(
        "#partial switch %s in kvist_place^ {{",
        payload_name,
    ))
    e.indent += 1
    emit_line(e, fmt.tprintf("case %s:", variant_type))
    e.indent += 1
    emit_automatic_native_delete_value(e, variant_type, payload_name)
    e.indent -= 1
    e.indent -= 1
    emit_line(e, "}")
    e.indent -= 1
    emit_line(e, "}")
    e.indent -= 1
    emit_line(e, fmt.tprintf(
        "})(%s, &%s)",
        address_of_expr_text(value_name),
        owner_flag,
    ))
    return true
}

emit_owned_aggregate_result_immediate_cleanup :: proc(
    e: ^Emitter,
    form: CST_Form,
    result_index, result_count: int,
    value_name: string,
) -> bool {
    if value_name == "" {
        return false
    }
    fields := proc_call_owned_result_fields_at(
        e,
        form,
        result_index,
        result_count,
    )
    defer delete_struct_field_slice(&fields)
    if len(fields) == 0 {
        return false
    }
    for offset in 0..<len(fields) {
        field := fields[len(fields)-1-offset]
        emit_line_mapped(
            e,
            ownership_destroy_value_text(
                e,
                field.ty,
                fmt.tprintf("%s.%s", value_name, field.name),
            ),
            form.span,
        )
    }
    return true
}

emit_owned_aggregate_result_scope_cleanup :: proc(
    e: ^Emitter,
    binding: Binding,
    bindings: []Binding,
    binding_index: int,
    body: []CST_Form,
    result_index: int,
    value_name: string,
) -> bool {
    if value_name == "" {
        return false
    }
    fields := proc_call_owned_result_fields_at(
        e,
        binding.value,
        result_index,
        len(binding.pattern),
    )
    defer delete_struct_field_slice(&fields)
    if len(fields) == 0 {
        return false
    }
    root_safe := destructured_result_cleanup_is_safe(
        e,
        bindings,
        binding_index,
        body,
        value_name,
    )
    emitted := false
    for offset in 0..<len(fields) {
        field := fields[len(fields)-1-offset]
        field_name := fmt.tprintf("%s.%s", value_name, field.name)
        if ownership_ir_current_plan_tracks_aggregate_field(
            e,
            binding,
            value_name,
            field_name,
        ) {
            emitted = true
            delete(field_name)
            continue
        }
        if !root_safe {
            delete(field_name)
            continue
        }
        safe := destructured_result_cleanup_is_safe(
            e,
            bindings,
            binding_index,
            body,
            field_name,
        )
        if safe {
            emit_line(e, fmt.tprintf(
                "defer %s",
                ownership_destroy_value_text(e, field.ty, field_name),
            ))
            emitted = true
        }
        delete(field_name)
    }
    return emitted
}

emit_binding_assignment :: proc(e: ^Emitter, binding: Binding, value: string) {
    if binding.is_destructure {
        output_names: [dynamic]string
        synthetic: [dynamic]bool
        cleanup_discard: [dynamic]bool
        defer {
            for name, idx in output_names {
                if synthetic[idx] {
                    delete(name)
                }
            }
            delete(output_names)
            delete(synthetic)
            delete(cleanup_discard)
        }
        for name in binding.pattern {
            append(&output_names, name)
            append(&synthetic, false)
            append(&cleanup_discard, false)
        }
        for name, idx in binding.pattern {
            if name != "" {
                continue
            }
            lifecycle, known := infer_result_lifecycle(
                e,
                binding.value,
                idx,
                len(binding.pattern),
            )
            owned := known && result_lifecycle_is_owned(lifecycle)
            result_lifecycle_delete(&lifecycle)
            if !owned {
                owned = result_has_owned_aggregate_fields(
                    e,
                    binding.value,
                    idx,
                    len(binding.pattern),
                )
            }
            if !owned {
                owned = result_has_owned_union_variant(
                    e,
                    binding.value,
                    idx,
                    len(binding.pattern),
                )
            }
            if !owned {
                continue
            }
            output_names[idx] = thread_temp_name(e)
            synthetic[idx] = true
            cleanup_discard[idx] = true
        }
        for should_cleanup, idx in cleanup_discard {
            if !should_cleanup {
                continue
            }
            lifecycle, known := infer_result_lifecycle(
                e,
                binding.value,
                idx,
                len(binding.pattern),
            )
            if known && lifecycle.condition != .Always &&
               lifecycle.condition_index >= 0 &&
               lifecycle.condition_index < len(output_names) &&
               output_names[lifecycle.condition_index] == "" {
                condition_index := lifecycle.condition_index
                output_names[condition_index] = thread_temp_name(e)
                synthetic[condition_index] = true
            }
            result_lifecycle_delete(&lifecycle)
        }
        line_builder := strings.builder_make()
        defer strings.builder_destroy(&line_builder)
        for name, idx in output_names {
            if idx > 0 {
                strings.write_string(&line_builder, ", ")
            }
            strings.write_string(&line_builder, binding_output_name(name))
        }
        fmt.sbprintf(&line_builder, " := %s", value)
        emit_prefixed_expr_mapped(e, "", strings.clone(strings.to_string(line_builder)), binding.value.span)
        for should_cleanup, idx in cleanup_discard {
            if !should_cleanup {
                continue
            }
            lifecycle, known := infer_result_lifecycle(
                e,
                binding.value,
                idx,
                len(binding.pattern),
            )
            if known && result_lifecycle_is_owned(lifecycle) {
                emit_result_lifecycle_immediate_cleanup(
                    e,
                    lifecycle,
                    output_names[:],
                    idx,
                )
            } else {
                cleaned_aggregate :=
                    emit_owned_aggregate_result_immediate_cleanup(
                    e,
                    binding.value,
                    idx,
                    len(binding.pattern),
                    output_names[idx],
                )
                if !cleaned_aggregate {
                    _ = emit_owned_union_result_cleanup(
                        e,
                        binding.value,
                        idx,
                        len(binding.pattern),
                        output_names[idx],
                        false,
                    )
                }
            }
            result_lifecycle_delete(&lifecycle)
        }
    } else if binding.is_result_binding {
        line_builder := strings.builder_make()
        defer strings.builder_destroy(&line_builder)
        for name, idx in binding.pattern {
            if idx > 0 {
                strings.write_string(&line_builder, ", ")
            }
            strings.write_string(&line_builder, binding_output_name(name))
        }
        fmt.sbprintf(&line_builder, " := %s", value)
        emit_prefixed_expr_mapped(e, "", strings.clone(strings.to_string(line_builder)), binding.value.span)
    } else if binding.name == "" {
        lifecycle, known := infer_result_lifecycle(
            e,
            binding.value,
            0,
            1,
        )
        owned_lifecycle := known && result_lifecycle_is_owned(lifecycle)
        owned_aggregate := result_has_owned_aggregate_fields(
            e,
            binding.value,
            0,
            1,
        )
        owned_union := result_has_owned_union_variant(
            e,
            binding.value,
            0,
            1,
        )
        if owned_lifecycle || owned_aggregate || owned_union {
            discard_name := thread_temp_name(e)
            defer delete(discard_name)
            emit_prefixed_expr_mapped(
                e,
                fmt.tprintf("%s := ", discard_name),
                value,
                binding.value.span,
            )
            discard_pattern := [1]string{discard_name}
            if owned_lifecycle {
                emit_result_lifecycle_immediate_cleanup(
                    e,
                    lifecycle,
                    discard_pattern[:],
                    0,
                )
            } else {
                cleaned_aggregate :=
                    emit_owned_aggregate_result_immediate_cleanup(
                    e,
                    binding.value,
                    0,
                    1,
                    discard_name,
                )
                if !cleaned_aggregate {
                    _ = emit_owned_union_result_cleanup(
                        e,
                        binding.value,
                        0,
                        1,
                        discard_name,
                        false,
                    )
                }
            }
        } else {
            emit_prefixed_expr_mapped(e, "_ = ", value, binding.value.span)
        }
        result_lifecycle_delete(&lifecycle)
    } else if binding.is_typed {
        emit_prefixed_expr_mapped(e, fmt.tprintf("%s: %s = ", binding.name, binding.ty), value, binding.value.span)
    } else {
        emit_prefixed_expr_mapped(e, fmt.tprintf("%s := ", binding.name), value, binding.value.span)
    }
}

binding_delete_target_name :: proc(binding: Binding) -> (string, bool) {
    if binding.name != "" {
        return binding.name, true
    }
    if (binding.is_result_binding || binding.is_destructure) && len(binding.pattern) > 0 {
        if binding.pattern[0] != "" {
            return binding.pattern[0], true
        }
    }
    return "", false
}

binding_has_explicit_cleanup_for_name :: proc(binding: Binding, name: string) -> bool {
    if !binding.deferred_delete &&
       !binding.err_deferred_delete &&
       !binding.defer_with_cleanup {
        return false
    }
    cleanup_name, ok := binding_delete_target_name(binding)
    return ok && cleanup_name == name
}

emit_binding_deferred_delete :: proc(e: ^Emitter, binding: Binding) -> (Compile_Error, bool) {
    delete_name, ok_delete_name := binding_delete_target_name(binding)
    if !ok_delete_name {
        return Compile_Error{message = ":defer binding marker is only supported on delete-able local bindings", span = binding.value.span}, false
    }
    emit_line(e, fmt.tprintf("defer delete(%s)", delete_name))
    return {}, true
}

emit_binding_defer_with_cleanup :: proc(e: ^Emitter, binding: Binding) -> (Compile_Error, bool) {
    delete_name, ok_delete_name := binding_delete_target_name(binding)
    if !ok_delete_name {
        return Compile_Error{message = ":defer-with binding marker is only supported on cleanable local bindings", span = binding.value.span}, false
    }
    cleanup, err_cleanup, ok_cleanup := emit_expr(e, binding.cleanup)
    if !ok_cleanup {
        return err_cleanup, false
    }
    emit_line(e, fmt.tprintf("defer %s(%s)", cleanup, delete_name))
    return {}, true
}

emit_binding_err_deferred_delete :: proc(e: ^Emitter, binding: Binding) -> (Compile_Error, bool) {
    delete_name, ok_delete_name := binding_delete_target_name(binding)
    if !ok_delete_name {
        return Compile_Error{message = ":errdefer binding marker is only supported on delete-able local bindings", span = binding.value.span}, false
    }
    if !binding.is_result_binding || binding.or_modifier != "or-return" || len(binding.pattern) != 2 || binding.pattern[1] != "err" {
        return Compile_Error{message = ":errdefer is only supported on [value err] :or-return bindings", span = binding.value.span}, false
    }
    emit_line(e, "defer {")
    e.indent += 1
    emit_line(e, "if err != nil {")
    e.indent += 1
    emit_line(e, fmt.tprintf("delete(%s)", delete_name))
    e.indent -= 1
    emit_line(e, "}")
    e.indent -= 1
    emit_line(e, "}")
    return {}, true
}

named_returns_match_binding_pattern :: proc(returns: Return_Spec, pattern: []string) -> bool {
    if returns.kind != .Named || len(returns.named) != len(pattern) {
        return false
    }
    for item, idx in pattern {
        if item == "" {
            return false
        }
        if returns.named[idx].name != item {
            return false
        }
    }
    return true
}

emit_result_binding_guard :: proc(e: ^Emitter, binding: Binding, returns: Return_Spec) -> (Compile_Error, bool) {
    if !binding.is_result_binding {
        return {}, true
    }
    if len(binding.pattern) != 2 {
        return Compile_Error{message = "or-* let binding expects exactly two names", span = binding.value.span}, false
    }
    status_name := binding.pattern[1]
    condition := ""
    switch status_name {
    case "ok":
        condition = fmt.tprintf("!%s", status_name)
    case "err":
        condition = fmt.tprintf("%s != nil", status_name)
    case:
        return Compile_Error{message = "or-* let binding requires [value ok] or [value err]", span = binding.value.span}, false
    }

    action := ""
    switch binding.or_modifier {
    case "or-break":
        action = "break"
    case "or-continue":
        action = "continue"
    case "or-return":
        if !named_returns_match_binding_pattern(returns, binding.pattern[:]) {
            return Compile_Error{
                message = ":or-return currently requires proc named returns matching the binding names exactly",
                span = binding.value.span,
            }, false
        }
        action = "return"
    case:
        return Compile_Error{message = "unsupported let binding modifier", span = binding.value.span}, false
    }

    emit_line(e, fmt.tprintf("if %s {{", condition))
    e.indent += 1
    emit_line(e, action)
    e.indent -= 1
    emit_line(e, "}")
    return {}, true
}

slice_all_expr_text :: proc(text: string) -> string {
    if len(text) >= 2 && text[0] == '[' && text[1] == ']' {
        return text
    }
    return fmt.tprintf("(%s)[:]", text)
}

address_of_expr_text :: proc(text: string) -> string {
    return fmt.tprintf("&(%s)", text)
}

deref_expr_text :: proc(text: string) -> string {
    if is_plain_identifier_text(text) {
        return fmt.tprintf("%s^", text)
    }
    return fmt.tprintf("(%s)^", text)
}

addr_expr_text :: proc(text: string) -> string {
    if is_plain_identifier_text(text) {
        return fmt.tprintf("&%s", text)
    }
    return fmt.tprintf("&(%s)", text)
}

symbol_is_simple_deref_suffix :: proc(text: string) -> bool {
    return len(text) > 1 && text[len(text)-1] == '^' && is_plain_identifier_text(map_name(text[:len(text)-1]))
}

field_from_selector :: proc(form: CST_Form) -> (field: string, ok: bool) {
    if form.kind == .Symbol && len(form.text) > 1 && form.text[0] == '.' {
        return map_name(form.text[1:]), true
    }
    return "", false
}

field_selector_looks_like_field :: proc(form: CST_Form) -> bool {
    if form.kind != .Symbol || len(form.text) <= 1 || form.text[0] != '.' {
        return false
    }
    ch := form.text[1]
    return (ch >= 'a' && ch <= 'z') || ch == '_'
}

selector_accesses_field :: proc(e: ^Emitter, target_form, selector_form: CST_Form) -> (field: string, ok: bool) {
    selector_field, ok_field := field_from_selector(selector_form)
    if !ok_field {
        return "", false
    }
    if target_form.kind == .Symbol {
        target_name := target_form.text
        if symbol_is_simple_deref_suffix(target_name) {
            target_name = target_name[:len(target_name)-1]
        }
        if target_ty, ok_ty := lookup_local_type(e, map_name(target_name)); ok_ty {
            ty := target_ty
            if strings.has_prefix(ty, "^") {
                ty = ty[1:]
            }
            if _, ok_struct := find_struct_decl(e, ty); ok_struct {
                return selector_field, true
            }
            return "", false
        }
    }
    if field_selector_looks_like_field(selector_form) {
        return selector_field, true
    }
    return "", false
}

field_type_expr_text :: proc(collection, field: string) -> string {
    return fmt.tprintf("type_of((%s)[0].%s)", collection, field)
}

type_text_is_dynamic_array :: proc(text: string) -> bool {
    return len(text) >= 9 && text[:9] == "[dynamic]"
}

type_text_is_pointer_to_dynamic_array :: proc(text: string) -> bool {
    return len(text) >= 10 && text[:10] == "^[dynamic]"
}

type_text_is_slice_or_fixed_array :: proc(text: string) -> bool {
    return len(text) >= 2 && text[0] == '[' && !type_text_is_dynamic_array(text) ||
           type_text_is_soa(text) && !type_text_is_dynamic_soa(text)
}

type_text_is_fixed_array :: proc(text: string) -> bool {
    return len(text) > 2 && text[0] == '[' && text[1] != ']' && !type_text_is_dynamic_array(text)
}

type_text_is_map :: proc(text: string) -> bool {
    return len(text) >= 4 && text[:4] == "map["
}

type_text_is_pointer_to_map :: proc(text: string) -> bool {
    return len(text) >= 5 && text[0] == '^' && type_text_is_map(text[1:])
}

set_element_type :: proc(text: string) -> (string, bool) {
    if key_ty, value_ty, ok_map := map_type_parts(text); ok_map && value_ty == "struct{}" {
        return key_ty, true
    }
    return "", false
}

map_index_target_text :: proc(e: ^Emitter, form: CST_Form, emitted: string) -> string {
    if ty, ok_ty := obvious_form_type(e, form); ok_ty && type_text_is_pointer_to_map(ty) {
        return deref_expr_text(emitted)
    }
    return emitted
}

mutation_target_text :: proc(e: ^Emitter, form: CST_Form, emitted: string) -> string {
    if ty, ok_ty := obvious_form_type(e, form); ok_ty {
        if type_text_is_pointer_to_map(ty) || type_text_is_pointer_to_dynamic_array(ty) {
            return emitted
        }
        if type_text_is_dynamic_array(ty) {
            return addr_expr_text(emitted)
        }
    }
    return address_of_expr_text(emitted)
}

type_text_is_owned_result :: proc(text: string) -> bool {
    return type_text_is_dynamic_array(text) || type_text_is_dynamic_soa(text) || type_text_is_map(text)
}

type_text_is_managed_value :: proc(e: ^Emitter, text: string) -> bool {
    if strings.trim_space(text) != "Data" {
        return false
    }
    // A source declaration named Data is an ordinary native type. The
    // built-in shared Data value exists only when that name is otherwise
    // unresolved in the current package.
    if e != nil {
        _, shadows_builtin := find_struct_decl(e, "Data")
        if shadows_builtin {
            return false
        }
    }
    return true
}

type_text_has_owned_lifecycle :: proc(e: ^Emitter, text: string) -> bool {
    return type_text_has_managed_lifecycle(e, text)
}

type_text_has_managed_lifecycle :: proc(e: ^Emitter, text: string, depth: int = 0) -> bool {
    if type_text_is_managed_value(e, text) {
        return true
    }
    if e == nil || depth > 16 {
        return false
    }
    struct_decl, ok_struct := find_struct_decl(e, strings.trim_space(text))
    if !ok_struct {
        return false
    }
    for field in struct_decl.fields {
        if field.owns_string ||
           field.owns_dynamic_array ||
           type_text_has_managed_lifecycle(e, field.ty, depth+1) {
            return true
        }
    }
    return false
}

type_text_has_data_lifecycle :: proc(e: ^Emitter, text: string, depth: int = 0) -> bool {
    if type_text_is_managed_value(e, text) {
        return true
    }
    if e == nil || depth > 16 {
        return false
    }
    struct_decl, ok_struct := find_struct_decl(e, strings.trim_space(text))
    if !ok_struct {
        return false
    }
    for field in struct_decl.fields {
        if type_text_has_data_lifecycle(e, field.ty, depth+1) {
            return true
        }
    }
    return false
}

managed_struct_helper_name :: proc(op, ty: string) -> string {
    return fmt.tprintf("kvist_managed_%s_%s", op, ty)
}

managed_clone_value_text :: proc(e: ^Emitter, ty, value: string) -> string {
    if type_text_is_string(ty) {
        mark_core_strings(e)
        return emit_call_text("strings.clone", []string{value})
    }
    if type_text_is_managed_value(e, ty) {
        mark_data_type(e)
        return emit_call_text("kvist_data_retain", []string{value})
    }
    if elem_ty, ok_dynamic := dynamic_array_element_type(ty); ok_dynamic {
        if type_text_has_managed_lifecycle(e, elem_ty) {
            cloned_item := managed_clone_value_text(e, elem_ty, "kvist_item")
            return fmt.tprintf(
                "(proc(kvist_values: %s) -> %s {{ kvist_out := make(%s, 0, len(kvist_values)); for kvist_item in kvist_values {{ append(&kvist_out, %s) }}; return kvist_out }})(%s)",
                ty,
                ty,
                ty,
                cloned_item,
                value,
            )
        }
        return fmt.tprintf(
            "(proc(kvist_values: %s) -> %s {{ kvist_out := make(%s, len(kvist_values)); copy(kvist_out[:], kvist_values[:]); return kvist_out }})(%s)",
            ty,
            ty,
            ty,
            value,
        )
    }
    if key_ty, value_ty, ok_map := map_type_parts(ty); ok_map {
        cloned_key := "kvist_key"
        if type_text_needs_managed_copy(e, key_ty) {
            cloned_key = managed_clone_value_text(e, key_ty, cloned_key)
        }
        cloned_value := "kvist_value"
        if type_text_needs_managed_copy(e, value_ty) {
            cloned_value =
                managed_clone_value_text(e, value_ty, cloned_value)
        }
        return fmt.tprintf(
            "(proc(kvist_values: %s) -> %s {{ kvist_out := make(%s, len(kvist_values)); for kvist_key, kvist_value in kvist_values {{ kvist_out[%s] = %s }}; return kvist_out }})(%s)",
            ty,
            ty,
            ty,
            cloned_key,
            cloned_value,
            value,
        )
    }
    return emit_call_text(managed_struct_helper_name("clone", ty), []string{value})
}

managed_destroy_value_text :: proc(e: ^Emitter, ty, value: string) -> string {
    if type_text_is_string(ty) {
        return emit_call_text("delete", []string{value})
    }
    if type_text_is_managed_value(e, ty) {
        mark_data_type(e)
        return emit_call_text("kvist_data_release", []string{value})
    }
    if elem_ty, ok_dynamic := dynamic_array_element_type(ty); ok_dynamic {
        if type_text_has_managed_lifecycle(e, elem_ty) {
            destroyed_item := managed_destroy_value_text(e, elem_ty, "kvist_item")
            return fmt.tprintf(
                "(proc(kvist_values: %s) {{ for kvist_item in kvist_values {{ %s }}; delete(kvist_values) }})(%s)",
                ty,
                destroyed_item,
                value,
            )
        }
        return emit_call_text("delete", []string{value})
    }
    if _, _, ok_map := map_type_parts(ty); ok_map {
        // A live REPL map can be mutated with ordinary Odin map assignment.
        // Such an assignment may introduce static or borrowed string
        // descriptors, so recursively destroying entry payloads would be
        // unsound. Reclaim the map backing store and leave cloned entry
        // payloads alive until the worker exits instead.
        return emit_call_text("delete", []string{value})
    }
    return emit_call_text(managed_struct_helper_name("destroy", ty), []string{value})
}

ownership_type_has_destructor :: proc(e: ^Emitter, ty: string) -> bool {
    trimmed := strings.trim_space(ty)
    return trimmed == "string" ||
           type_text_is_slice(trimmed) ||
           type_text_is_dynamic_array(trimmed) ||
           type_text_is_dynamic_soa(trimmed) ||
           type_text_is_map(trimmed) ||
           type_text_has_managed_lifecycle(e, trimmed)
}

ownership_destroy_value_text :: proc(e: ^Emitter, ty, value: string) -> string {
    trimmed := strings.trim_space(ty)
    if trimmed == "string" ||
       type_text_is_slice(trimmed) ||
       type_text_is_dynamic_soa(trimmed) ||
       type_text_is_map(trimmed) {
        return emit_call_text("delete", []string{value})
    }
    return managed_destroy_value_text(e, trimmed, value)
}

managed_move_local_value_text :: proc(e: ^Emitter, ty, value, owner_flag: string) -> string {
    return fmt.tprintf(
        "(proc(kvist_value: %s, kvist_owner: ^bool) -> %s {{ kvist_owner^ = false; return kvist_value }})(%s, &%s)",
        ty,
        ty,
        value,
        owner_flag,
    )
}

managed_owner_flag_name :: proc(e: ^Emitter) -> string {
    e.owner_counter += 1
    return fmt.tprintf("kvist_owner_%d", e.owner_counter)
}

managed_dynamic_array_assignment_text :: proc(
    e: ^Emitter,
    ty, place, value: string,
    move: bool,
) -> string {
    destroy_previous := managed_destroy_value_text(e, ty, "kvist_previous")
    if move {
        return fmt.tprintf(
            "(proc(kvist_place: ^%s, kvist_value: %s) {{ kvist_previous := kvist_place^; kvist_place^ = kvist_value; %s }})(%s, %s)",
            ty,
            ty,
            destroy_previous,
            place,
            value,
        )
    }
    replacement := managed_clone_value_text(e, ty, "kvist_value")
    return fmt.tprintf(
        "(proc(kvist_place: ^%s, kvist_value: %s) {{ kvist_replacement := %s; kvist_previous := kvist_place^; kvist_place^ = kvist_replacement; %s }})(%s, %s)",
        ty,
        ty,
        replacement,
        destroy_previous,
        place,
        value,
    )
}

managed_assign_helper_name :: proc(e: ^Emitter, ty: string, move: bool) -> string {
    if type_text_is_managed_value(e, ty) {
        return "kvist_data_move_assign" if move else "kvist_data_assign"
    }
    return managed_struct_helper_name("move_assign" if move else "assign", ty)
}

emit_managed_struct_helpers :: proc(e: ^Emitter, struct_decl: Struct_Decl) {
    if !type_text_has_managed_lifecycle(e, struct_decl.name) {
        return
    }
    clone_name := managed_struct_helper_name("clone", struct_decl.name)
    destroy_name := managed_struct_helper_name("destroy", struct_decl.name)
    assign_name := managed_struct_helper_name("assign", struct_decl.name)
    move_assign_name := managed_struct_helper_name("move_assign", struct_decl.name)

    emit_raw_newline(e)
    emit_line(e, fmt.tprintf("%s :: proc(value: %s) -> %s {{", clone_name, struct_decl.name, struct_decl.name))
    e.indent += 1
    emit_line(e, "out := value")
    for field in struct_decl.fields {
        if field.owns_string {
            mark_core_strings(e)
            emit_line(e, fmt.tprintf("out.%s = strings.clone(value.%s)", field.name, field.name))
        } else if field.owns_dynamic_array {
            cloned := managed_clone_value_text(e, field.ty, fmt.tprintf("value.%s", field.name))
            emit_line(e, fmt.tprintf("out.%s = %s", field.name, cloned))
        } else if type_text_has_managed_lifecycle(e, field.ty) {
            retained := managed_clone_value_text(e, field.ty, fmt.tprintf("value.%s", field.name))
            emit_line(e, fmt.tprintf("out.%s = %s", field.name, retained))
        }
    }
    emit_line(e, "return out")
    e.indent -= 1
    emit_line(e, "}")

    emit_raw_newline(e)
    emit_line(e, fmt.tprintf("%s :: proc(value: %s) {{", destroy_name, struct_decl.name))
    e.indent += 1
    for offset in 0..<len(struct_decl.fields) {
        field := struct_decl.fields[len(struct_decl.fields)-1-offset]
        if field.owns_string {
            emit_line(e, fmt.tprintf("delete(value.%s)", field.name))
        } else if field.owns_dynamic_array {
            emit_line(e, managed_destroy_value_text(e, field.ty, fmt.tprintf("value.%s", field.name)))
        } else if type_text_has_managed_lifecycle(e, field.ty) {
            emit_line(e, managed_destroy_value_text(e, field.ty, fmt.tprintf("value.%s", field.name)))
        }
    }
    e.indent -= 1
    emit_line(e, "}")

    emit_raw_newline(e)
    emit_line(e, fmt.tprintf("%s :: proc(place: ^%s, value: %s) {{", assign_name, struct_decl.name, struct_decl.name))
    e.indent += 1
    emit_line(e, fmt.tprintf("replacement := %s(value)", clone_name))
    emit_line(e, "previous := place^")
    emit_line(e, "place^ = replacement")
    emit_line(e, fmt.tprintf("%s(previous)", destroy_name))
    e.indent -= 1
    emit_line(e, "}")

    emit_raw_newline(e)
    emit_line(e, fmt.tprintf("%s :: proc(place: ^%s, value: %s) {{", move_assign_name, struct_decl.name, struct_decl.name))
    e.indent += 1
    emit_line(e, "previous := place^")
    emit_line(e, "place^ = value")
    emit_line(e, fmt.tprintf("%s(previous)", destroy_name))
    e.indent -= 1
    emit_line(e, "}")
}

form_produces_owned_managed_value :: proc(e: ^Emitter, form: CST_Form, depth: int = 0) -> bool {
    if depth > 8 || form.kind != .List || len(form.items) == 0 || form.items[0].kind != .Symbol {
        return false
    }
    if form.items[0].text == "quasiquote" {
        return true
    }
    if form.items[0].text == "Data" && len(form.items) == 2 {
        value := form.items[1]
        if value.kind == .Vector || value.kind == .Brace || value.kind == .Set {
            return true
        }
        if value.kind == .Nil ||
           value.kind == .Bool ||
           value.kind == .Number ||
           value.kind == .String ||
           value.kind == .Keyword {
            return false
        }
        if value_ty, ok_value_ty := obvious_form_type(e, value);
           ok_value_ty && type_text_is_managed_value(e, value_ty) {
            return form_produces_owned_managed_value(e, value, depth+1)
        }
        return true
    }
    if form.items[0].text == "into" {
        output_ty, _, _, ok_output_ty := parse_type_text_from_forms(form.items[:], 1)
        if ok_output_ty {
            defer delete(output_ty)
            if type_text_is_managed_value(e, output_ty) {
                return true
            }
        }
    }
    if head_is_core_assoc(form.items[0].text) ||
       head_is_core_update(form.items[0].text) ||
       head_is_core_dissoc(form.items[0].text) {
        if ty, ok_ty := obvious_form_type(e, form); ok_ty && type_text_is_managed_value(e, ty) {
            return true
        }
    }
    switch form.items[0].text {
    case "if", "let", "do", "block", "type-case", "match":
        if ty, ok_ty := obvious_form_type(e, form);
           ok_ty && type_text_is_managed_value(e, ty) {
            // Data-valued control-flow expressions normalize each branch to
            // one owned reference before the surrounding binding receives it.
            return true
        }
    }
    if form_infers_known_foreign_lifetime(form, .Owned, depth+1, e) {
        return true
    }
    if _, proc_decl, ok_proc := resolve_proc_call_decl(e, form.items[0].text);
       ok_proc && proc_decl != nil {
        // Every Kvist procedure returning Data hands its caller one stable
        // reference. A borrowed value in the body is retained at the return
        // boundary, while an already-owned value is transferred. `owns_result`
        // describes the body's provenance, not a different public calling
        // convention.
        return proc_decl.returns.kind == .Single &&
               type_text_is_managed_value(e, proc_decl.returns.single_ty)
    }
    overload_name := map_name(form.items[0].text)
    defer delete(overload_name)
    if overload_return_ty, ok_overload :=
           overload_obvious_call_return_type(e, overload_name, form.items[1:]);
       ok_overload {
        defer delete(overload_return_ty)
        if type_text_is_managed_value(e, overload_return_ty) {
            // Every selected Kvist overload member follows the same Data
            // calling convention as an ordinary procedure: one stable
            // caller-owned reference.
            return true
        }
    }
    return false
}

form_produces_owned_managed_type :: proc(
    e: ^Emitter,
    form: CST_Form,
    ty: string,
    depth: int = 0,
    owned_names: []string = nil,
) -> bool {
    if type_text_is_managed_value(e, ty) {
        if form.kind == .Vector || form.kind == .Brace || form.kind == .Set {
            return true
        }
        if form.kind == .List && len(form.items) > 0 && form.items[0].kind == .Symbol {
            switch form.items[0].text {
            case "if", "when", "cond", "case":
                // These surface forms lower to Data-normalized `if`
                // expressions when their call/binding context expects Data.
                // Treat the whole result as the one owned branch reference so
                // a borrowed call argument is hoisted and released exactly
                // once rather than retaining an untracked inline temporary.
                return true
            }
        }
        return form_produces_owned_managed_value(e, form, depth)
    }
    if depth > 8 || !type_text_has_owned_lifecycle(e, ty) {
        return false
    }
    if form.kind == .Symbol {
        name := map_name(form.text)
        defer delete(name)
        return string_slice_contains_name(owned_names, name)
    }
    if form.kind != .List || len(form.items) == 0 || form.items[0].kind != .Symbol {
        return false
    }
    head_name := map_name(form.items[0].text)
    defer delete(head_name)
    if head_name == ty {
        if _, ok_struct := find_struct_decl(e, head_name); ok_struct {
            return true
        }
    }
    if head_name == ty && form_is_struct_or_union_constructor(e, form) {
        return true
    }
    if form.items[0].text == "copy-with" || form.items[0].text == "copy-update" {
        if result_ty, ok_result_ty := obvious_form_type(e, form); ok_result_ty && result_ty == ty {
            return true
        }
    }
    switch form.items[0].text {
    case "return":
        return len(form.items) == 2 &&
               form_produces_owned_managed_type(e, form.items[1], ty, depth+1, owned_names)
    case "do", "block":
        return len(form.items) > 1 &&
               form_produces_owned_managed_type(
                   e,
                   form.items[len(form.items)-1],
                   ty,
                   depth+1,
                   owned_names,
               )
    case "if":
        return len(form.items) == 4 &&
               form_produces_owned_managed_type(e, form.items[2], ty, depth+1, owned_names) &&
               form_produces_owned_managed_type(e, form.items[3], ty, depth+1, owned_names)
    case "let":
        if len(form.items) < 3 {
            return false
        }
        bindings, _, ok_bind := parse_let_bindings(form.items[1])
        if !ok_bind {
            return false
        }
        scoped_names: [dynamic]string
        append(&scoped_names, ..owned_names)
        for binding in bindings {
            if binding.is_destructure {
                continue
            }
            binding_ty, ok_binding_ty := obvious_binding_type(e, binding)
            if binding.name != "" &&
               ok_binding_ty &&
               binding_ty == ty &&
               form_produces_owned_managed_type(
                   e,
                   binding.value,
                   ty,
                   depth+1,
                   scoped_names[:],
               ) {
                append(&scoped_names, binding.name)
            }
        }
        return form_produces_owned_managed_type(
            e,
            form.items[len(form.items)-1],
            ty,
            depth+1,
            scoped_names[:],
        )
    }
    if _, proc_decl, ok_proc := resolve_proc_call_decl(e, form.items[0].text);
       ok_proc && proc_decl != nil {
        contract := procedure_result_ownership_contract(proc_decl, e)
        defer procedure_ownership_contract_delete(&contract)
        return proc_decl.returns.kind == .Single &&
               proc_decl.returns.single_ty == ty &&
               contract.result_flow == .Owned
    }
    return false
}

owned_managed_form_type :: proc(e: ^Emitter, form: CST_Form) -> (string, bool) {
    ty, ok_ty := obvious_form_type(e, form)
    if !ok_ty || !type_text_has_owned_lifecycle(e, ty) ||
       !form_produces_owned_managed_type(e, form, ty) {
        return "", false
    }
    return ty, true
}

form_has_active_store_event :: proc(e: ^Emitter, form: CST_Form) -> bool {
    if form.kind == .Symbol {
        name := map_name(form.text)
        defer delete(name)
        _, stored := ownership_ir_active_event_place(e, name, form.span, .Store)
        return stored
    }
    if owner_name, has_owner := form_direct_borrow_owner_name(form, e); has_owner {
        defer delete(owner_name)
        _, stored := ownership_ir_active_event_place(
            e,
            owner_name,
            form.span,
            .Store,
        )
        return stored
    }
    return false
}

stored_struct_constructor_fields :: proc(
    e: ^Emitter,
    form: CST_Form,
) -> [dynamic]Struct_Field {
    stored: [dynamic]Struct_Field
    if form.kind != .List || len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return stored
    }
    type_name := map_name(form.items[0].text)
    defer delete(type_name)
    struct_decl, ok_struct := find_struct_decl(e, type_name)
    if !ok_struct {
        return stored
    }
    args := form.items[1:]
    if struct_args_use_named_fields(args) {
        for i := 0; i+1 < len(args); i += 2 {
            field_name, ok_name := brace_key_name(args[i])
            if !ok_name || !form_has_active_store_event(e, args[i+1]) {
                continue
            }
            if field, ok_field := find_struct_field(struct_decl, field_name); ok_field {
                append(&stored, field^)
            }
        }
        return stored
    }
    for value, idx in args {
        if idx >= len(struct_decl.fields) {
            break
        }
        if form_has_active_store_event(e, value) {
            append(&stored, struct_decl.fields[idx])
        }
    }
    return stored
}

form_requires_owned_discard_cleanup :: proc(e: ^Emitter, form: CST_Form) -> bool {
    if form_produces_owned_value(form, e) {
        return true
    }
    if _, managed := owned_managed_form_type(e, form); managed {
        return true
    }
    stored_fields := stored_struct_constructor_fields(e, form)
    defer delete(stored_fields)
    if len(stored_fields) > 0 {
        return true
    }
    returned_fields := proc_call_owned_result_fields(e, form)
    defer delete_struct_field_slice(&returned_fields)
    return len(returned_fields) > 0
}

emit_owned_discard_cleanup :: proc(
    e: ^Emitter,
    form: CST_Form,
    expr: string,
    strategy := Ownership_IR_Automatic_Cleanup.None,
) -> bool {
    allow_managed := strategy == .None || strategy == .Managed
    allow_native := strategy == .None || strategy == .Native
    if managed_ty, managed := owned_managed_form_type(e, form);
       allow_managed && managed {
        temp := thread_temp_name(e)
        emit_prefixed_expr_mapped(e, fmt.tprintf("%s := ", temp), expr, form.span)
        emit_line_mapped(e, managed_destroy_value_text(e, managed_ty, temp), form.span)
        return true
    }
    stored_fields := stored_struct_constructor_fields(e, form)
    defer delete(stored_fields)
    if allow_managed && len(stored_fields) > 0 {
        temp := thread_temp_name(e)
        emit_prefixed_expr_mapped(e, fmt.tprintf("%s := ", temp), expr, form.span)
        for offset in 0..<len(stored_fields) {
            field := stored_fields[len(stored_fields)-1-offset]
            emit_line_mapped(
                e,
                ownership_destroy_value_text(
                    e,
                    field.ty,
                    fmt.tprintf("%s.%s", temp, field.name),
                ),
                form.span,
            )
        }
        return true
    }
    returned_fields := proc_call_owned_result_fields(e, form)
    defer delete_struct_field_slice(&returned_fields)
    if allow_managed && len(returned_fields) > 0 {
        temp := thread_temp_name(e)
        emit_prefixed_expr_mapped(e, fmt.tprintf("%s := ", temp), expr, form.span)
        for offset in 0..<len(returned_fields) {
            field := returned_fields[len(returned_fields)-1-offset]
            emit_line_mapped(
                e,
                ownership_destroy_value_text(
                    e,
                    field.ty,
                    fmt.tprintf("%s.%s", temp, field.name),
                ),
                form.span,
            )
        }
        return true
    }
    if allow_native && form_supports_automatic_native_delete(form, e) {
        temp := thread_temp_name(e)
        emit_prefixed_expr_mapped(e, fmt.tprintf("%s := ", temp), expr, form.span)
        emit_line_mapped(e, fmt.tprintf("delete(%s)", temp), form.span)
        return true
    }
    return false
}

emit_discarded_expr_value :: proc(e: ^Emitter, form: CST_Form, expr: string) {
    if form.kind == .List && len(form.items) > 0 && form.items[0].kind == .Symbol {
        if _, proc_decl, ok_proc := resolve_proc_call_decl(e, form.items[0].text);
           ok_proc && proc_decl != nil &&
           proc_decl.returns.kind == .Named && len(proc_decl.returns.named) > 1 {
            temps: [dynamic]string
            line_builder := strings.builder_make()
            defer strings.builder_destroy(&line_builder)
            for _ in proc_decl.returns.named {
                temp := thread_temp_name(e)
                append(&temps, temp)
                if len(temps) > 1 {
                    strings.write_string(&line_builder, ", ")
                }
                strings.write_string(&line_builder, temp)
            }
            strings.write_string(&line_builder, " := ")
            emit_prefixed_expr_mapped(
                e,
                strings.clone(strings.to_string(line_builder)),
                expr,
                form.span,
            )
            for temp in temps {
                emit_line_mapped(e, fmt.tprintf("_ = %s", temp), form.span)
            }
            delete(temps)
            return
        }
    }
    emit_prefixed_expr_mapped(e, "_ = ", expr, form.span)
}

emit_result_lifecycle_discard_cleanup :: proc(
    e: ^Emitter,
    form: CST_Form,
    expr: string,
) -> bool {
    result_count, known_count := result_lifecycle_call_result_count(e, form)
    if !known_count {
        result_count = 1
    }
    if result_count <= 0 {
        return false
    }
    lifecycles: [dynamic]Result_Lifecycle
    lifecycle_known: [dynamic]bool
    output_names: [dynamic]string
    synthetic: [dynamic]bool
    cleanup_result: [dynamic]bool
    defer {
        for lifecycle in lifecycles {
            lifecycle_copy := lifecycle
            result_lifecycle_delete(&lifecycle_copy)
        }
        for name, idx in output_names {
            if synthetic[idx] {
                delete(name)
            }
        }
        delete(lifecycles)
        delete(lifecycle_known)
        delete(output_names)
        delete(synthetic)
        delete(cleanup_result)
    }
    has_owned := false
    for result_index in 0..<result_count {
        lifecycle, known := infer_result_lifecycle(
            e,
            form,
            result_index,
            result_count,
        )
        owned := known && result_lifecycle_is_owned(lifecycle)
        if !owned && result_count > 1 {
            owned = result_has_owned_aggregate_fields(
                e,
                form,
                result_index,
                result_count,
            )
        }
        if !owned {
            owned = result_has_owned_union_variant(
                e,
                form,
                result_index,
                result_count,
            )
        }
        append(&lifecycles, lifecycle)
        append(&lifecycle_known, known)
        append(&output_names, "")
        append(&synthetic, false)
        append(&cleanup_result, owned)
        if owned {
            output_names[result_index] = thread_temp_name(e)
            synthetic[result_index] = true
            has_owned = true
        }
    }
    if !has_owned {
        return false
    }
    for should_cleanup, result_index in cleanup_result {
        if !should_cleanup {
            continue
        }
        lifecycle := lifecycles[result_index]
        if lifecycle.condition != .Always &&
           lifecycle.condition_index >= 0 &&
           lifecycle.condition_index < len(output_names) &&
           output_names[lifecycle.condition_index] == "" {
            condition_index := lifecycle.condition_index
            output_names[condition_index] = thread_temp_name(e)
            synthetic[condition_index] = true
        }
    }

    line_builder := strings.builder_make()
    defer strings.builder_destroy(&line_builder)
    for name, idx in output_names {
        if idx > 0 {
            strings.write_string(&line_builder, ", ")
        }
        strings.write_string(&line_builder, binding_output_name(name))
    }
    strings.write_string(&line_builder, " := ")
    emit_prefixed_expr_mapped(
        e,
        strings.clone(strings.to_string(line_builder)),
        expr,
        form.span,
    )
    for should_cleanup, result_index in cleanup_result {
        if !should_cleanup {
            continue
        }
        if lifecycle_known[result_index] &&
           result_lifecycle_is_owned(lifecycles[result_index]) {
            emit_result_lifecycle_immediate_cleanup(
                e,
                lifecycles[result_index],
                output_names[:],
                result_index,
            )
        } else {
            cleaned_aggregate :=
                emit_owned_aggregate_result_immediate_cleanup(
                e,
                form,
                result_index,
                result_count,
                output_names[result_index],
            )
            if !cleaned_aggregate {
                _ = emit_owned_union_result_cleanup(
                    e,
                    form,
                    result_index,
                    result_count,
                    output_names[result_index],
                    false,
                )
            }
        }
    }
    return true
}

emit_discarded_expr :: proc(e: ^Emitter, form: CST_Form, expr: string) {
    if emit_result_lifecycle_discard_cleanup(e, form, expr) {
        return
    }
    event, automatic_cleanup, tracked :=
        ownership_ir_current_transient_event(e, form)
    if tracked {
        if event == .Destroy &&
           automatic_cleanup != .None &&
           emit_owned_discard_cleanup(
               e,
               form,
               expr,
               automatic_cleanup,
           ) {
            e.ownership_plan_adoptions += 1
            return
        }
        emit_discarded_expr_value(e, form, expr)
        return
    }
    // Invalid or non-procedure plans retain the established lowering path.
    // Valid procedure plans always contain a transient for owned discards.
    if emit_owned_discard_cleanup(e, form, expr) {
        return
    }
    emit_discarded_expr_value(e, form, expr)
}

binding_supports_automatic_native_cleanup :: proc(e: ^Emitter, binding: Binding) -> bool {
    ty, ok_ty := obvious_binding_type(e, binding)
    return ok_ty &&
           ownership_type_has_destructor(e, ty) &&
           type_supports_automatic_native_delete(ty) &&
           binding_value_produces_owned_value(binding, e) &&
           !form_produces_owned_managed_type(e, binding.value, ty)
}

managed_binding_value_text :: proc(e: ^Emitter, binding: Binding, value: string) -> (text, managed_ty: string, managed, automatic_native: bool) {
    ty, ok_ty := obvious_binding_type(e, binding)
    if !ok_ty || !ownership_type_has_destructor(e, ty) || binding.name == "" || binding.is_destructure || binding.is_result_binding {
        return value, "", false, false
    }
    if form_produces_owned_managed_type(e, binding.value, ty) {
        return value, ty, true, false
    }
    if type_text_has_data_lifecycle(e, ty) {
        return managed_clone_value_text(e, ty, value), ty, true, false
    }
    if binding_supports_automatic_native_cleanup(e, binding) {
        // The emitter installs cleanup only after proving that this local is
        // not reassigned or transferred by the surrounding body.
        return value, ty, true, true
    }
    // Native strings, arrays, maps, and opaque resources retain Odin's
    // explicit lifetime style. Allocation and transfer inference still powers
    // diagnostics and `kvist lifetimes`, but does not silently install cleanup
    // for storage whose escape through native APIs cannot be proven.
    return value, "", false, false
}

managed_return_value_text_for_type :: proc(e: ^Emitter, form: CST_Form, value, return_ty: string) -> string {
    if form.kind == .Symbol {
        name := map_name(form.text)
        defer delete(name)
        if owner_flag, ok_owner := lookup_managed_local_owner(e, name); ok_owner {
            return managed_move_local_value_text(e, return_ty, value, owner_flag)
        }
    }
    if !ownership_type_has_destructor(e, return_ty) ||
       (e.current_proc_owns_managed_result &&
        !type_text_has_data_lifecycle(e, return_ty)) ||
       (e.current_proc_borrows_managed_result &&
        !type_text_has_data_lifecycle(e, return_ty)) ||
       form_produces_owned_managed_type(e, form, return_ty) ||
       form_produces_owned_value(form, e) {
        return value
    }
    if type_text_has_data_lifecycle(e, return_ty) {
        return managed_clone_value_text(e, return_ty, value)
    }
    return value
}

managed_return_value_text :: proc(e: ^Emitter, form: CST_Form, value: string, returns: Return_Spec) -> string {
    if returns.kind == .Single {
        return managed_return_value_text_for_type(e, form, value, returns.single_ty)
    }
    if returns.kind == .Named && len(returns.named) == 1 {
        return managed_return_value_text_for_type(e, form, value, returns.named[0].ty)
    }
    return value
}

emit_managed_destructure_cleanup :: proc(
    e: ^Emitter,
    binding: Binding,
    bindings: []Binding,
    binding_index: int,
    body: []CST_Form,
) {
    lifecycle_binding :=
        binding.is_destructure ||
        (binding.is_result_binding && binding.or_modifier != "or-return")
    if !lifecycle_binding ||
       binding.value.kind != .List ||
       len(binding.value.items) == 0 ||
       binding.value.items[0].kind != .Symbol {
        return
    }
    head_name := map_name(binding.value.items[0].text)
    defer delete(head_name)
    if binding.is_destructure &&
       head_name == "decode_data" &&
       len(binding.pattern) == 3 &&
       len(binding.value.items) >= 2 {
        target_ty, _, ok_target_ty := parse_type_text(binding.value.items[1])
        if ok_target_ty {
            if binding.pattern[0] != "" &&
               (type_text_has_managed_lifecycle(e, target_ty) ||
                type_text_is_owned_result(target_ty)) {
                emit_line(e, fmt.tprintf(
                    "defer %s",
                    managed_destroy_value_text(e, target_ty, binding.pattern[0]),
                ))
            }
            if binding.pattern[1] != "" {
                emit_line(e, fmt.tprintf(
                    "defer %s",
                    managed_destroy_value_text(e, "data__Decode_Error", binding.pattern[1]),
                ))
            }
        }
        return
    }
    if binding.is_destructure && head_name == "validate_data" && len(binding.pattern) == 2 {
        if binding.pattern[0] != "" {
            emit_line(e, fmt.tprintf(
                "defer %s",
                managed_destroy_value_text(e, "data__Decode_Error", binding.pattern[0]),
            ))
        }
        return
    }
    lifecycle_cleanup_handled: [dynamic]bool
    defer delete(lifecycle_cleanup_handled)
    for _ in binding.pattern {
        append(&lifecycle_cleanup_handled, false)
    }
    for name, idx in binding.pattern {
        if name == "" {
            continue
        }
        if binding_has_explicit_cleanup_for_name(binding, name) {
            continue
        }
        lifecycle, known := infer_result_lifecycle(
            e,
            binding.value,
            idx,
            len(binding.pattern),
        )
        if !known {
            cleaned_aggregate := emit_owned_aggregate_result_scope_cleanup(
                e,
                binding,
                bindings,
                binding_index,
                body,
                idx,
                name,
            )
            if !cleaned_aggregate &&
               !ownership_ir_current_plan_tracks_union_result(
                   e,
                   binding,
                   name,
               ) &&
               destructured_result_cleanup_is_safe(
                   e,
                   bindings,
                   binding_index,
                   body,
                   name,
               ) {
                _ = emit_owned_union_result_cleanup(
                    e,
                    binding.value,
                    idx,
                    len(binding.pattern),
                    name,
                    true,
                )
            }
            continue
        }
        expected_cleanup := Ownership_IR_Cleanup_Need.Always
        if lifecycle.condition != .Always {
            expected_cleanup = .Conditional
        }
        if per_exit_place, adopted :=
            ownership_ir_current_plan_per_exit_place(
                e,
                binding,
                name,
                expected_cleanup,
            ); adopted && ownership_ir_activate_per_exit_place(
                e,
                binding,
                lifecycle,
                per_exit_place,
            ) {
            e.ownership_plan_adoptions += 1
            lifecycle_cleanup_handled[idx] = true
            result_lifecycle_delete(&lifecycle)
            continue
        }
        if ownership_ir_current_plan_tracks_stored_owner(
            e,
            binding,
            name,
        ) {
            lifecycle_cleanup_handled[idx] = true
            result_lifecycle_delete(&lifecycle)
            continue
        }
        if !destructured_result_cleanup_is_safe(
            e,
            bindings,
            binding_index,
            body,
            name,
        ) {
            result_lifecycle_delete(&lifecycle)
            continue
        }
        if !result_lifecycle_condition_is_stable(
            lifecycle,
            binding.pattern[:],
            body,
        ) {
            result_lifecycle_delete(&lifecycle)
            continue
        }
        if ownership_ir_current_plan_authorizes_scope_cleanup(
            e,
            binding,
            name,
            expected_cleanup,
        ) {
            e.ownership_plan_adoptions += 1
            emit_result_lifecycle_cleanup(e, lifecycle, binding.pattern[:], idx)
            lifecycle_cleanup_handled[idx] = true
            result_lifecycle_delete(&lifecycle)
            continue
        }
        // All non-candidates retain the legacy path while the ownership plan
        // is introduced one proven-equivalent category at a time.
        emit_result_lifecycle_cleanup(e, lifecycle, binding.pattern[:], idx)
        lifecycle_cleanup_handled[idx] = true
        result_lifecycle_delete(&lifecycle)
    }
    if !binding.is_destructure {
        return
    }
    proc_decl, ok_proc := find_proc_decl(e, head_name)
    if !ok_proc {
        return
    }
    contract := procedure_result_ownership_contract(proc_decl, e)
    defer procedure_ownership_contract_delete(&contract)
    if contract.result_flow == .Borrowed ||
       proc_decl.returns.kind != .Named ||
       len(proc_decl.returns.named) != len(binding.pattern) {
        return
    }
    for name, idx in binding.pattern {
        if name == "" ||
           binding_has_explicit_cleanup_for_name(binding, name) ||
           lifecycle_cleanup_handled[idx] ||
           !type_text_has_managed_lifecycle(e, proc_decl.returns.named[idx].ty) ||
           body_deletes_name(body, name) {
            continue
        }
        // The result-lifecycle path above is authoritative when it installed
        // or adopted cleanup. The managed-type path remains the fallback for
        // Data results which still need ABI-level scoped cleanup. Letting both
        // paths install cleanup releases the same owned Data value twice.
        emit_line(e, fmt.tprintf(
            "defer %s",
            managed_destroy_value_text(e, proc_decl.returns.named[idx].ty, name),
        ))
    }
}

managed_assignment_text :: proc(
    e: ^Emitter,
    place_form, value_form: CST_Form,
    place, value: string,
    moves_tracked_local: bool,
) -> (string, bool) {
    if target_form, fields, _, ok_place := field_path_place_parts(place_form); ok_place {
        if target_ty, ok_target_ty := obvious_form_type(e, target_form);
           ok_target_ty && struct_field_owns_string_for_update_path(e, target_ty, fields[:]) {
            mark_core_strings(e)
            if moves_tracked_local || form_produces_owned_value(value_form, e) {
                return fmt.tprintf(
                    "(proc(kvist_place: ^string, kvist_value: string) {{ kvist_previous := kvist_place^; kvist_place^ = kvist_value; delete(kvist_previous) }})(%s, %s)",
                    address_of_expr_text(place),
                    value,
                ), true
            }
            return fmt.tprintf(
                "(proc(kvist_place: ^string, kvist_value: string) {{ kvist_replacement := strings.clone(kvist_value); kvist_previous := kvist_place^; kvist_place^ = kvist_replacement; delete(kvist_previous) }})(%s, %s)",
                address_of_expr_text(place),
                value,
            ), true
        }
        if target_ty, ok_target_ty := obvious_form_type(e, target_form);
           ok_target_ty &&
           struct_field_owns_dynamic_array_for_update_path(e, target_ty, fields[:]) {
            field_ty, err_field_ty, ok_field_ty := struct_field_type_for_update_path(
                e,
                target_ty,
                fields[:],
                "set!",
                place_form.span,
            )
            _ = err_field_ty
            if ok_field_ty {
                move := moves_tracked_local || form_produces_owned_value(value_form, e)
                return managed_dynamic_array_assignment_text(
                    e,
                    field_ty,
                    address_of_expr_text(place),
                    value,
                    move,
                ), true
            }
        }
    }
    place_ty, ok_place_ty := obvious_form_type(e, place_form)
    if !ok_place_ty {
        return "", false
    }
    is_repl_dynamic_place :=
        place_form.kind == .Symbol &&
        name_in_list(e.repl_var_names, map_name(place_form.text)) &&
        type_text_is_dynamic_array(place_ty)
    is_repl_map_place :=
        place_form.kind == .Symbol &&
        name_in_list(e.repl_var_names, map_name(place_form.text)) &&
        type_text_is_map(place_ty)
    if is_repl_dynamic_place || is_repl_map_place {
        move := moves_tracked_local || form_produces_owned_value(value_form, e)
        if is_repl_map_place {
            // REPL map storage owns normalized copies of string and managed
            // entries. A literal or ordinary owned map may still contain
            // static or borrowed entry descriptors, so never move it directly
            // into a cell that will later destroy those entries.
            move = false
        }
        return managed_dynamic_array_assignment_text(
            e,
            place_ty,
            address_of_expr_text(place),
            value,
            move,
        ), true
    }
    if !type_text_has_owned_lifecycle(e, place_ty) {
        return "", false
    }
    move := moves_tracked_local || form_produces_owned_managed_type(e, value_form, place_ty)
    helper := managed_assign_helper_name(e, place_ty, move)
    return emit_call_text(helper, []string{address_of_expr_text(place), value}), true
}

assignment_move_tracked_local_text :: proc(
    e: ^Emitter,
    place_form, value_form: CST_Form,
    value: string,
) -> (string, bool) {
    if value_form.kind != .Symbol {
        return value, false
    }
    source_name := map_name(value_form.text)
    if source_name == "" {
        return value, false
    }
    if place_form.kind == .Symbol && map_name(place_form.text) == source_name {
        return value, false
    }
    owner_flag, has_owner := lookup_managed_local_owner(e, source_name)
    if !has_owner {
        owner_flag, has_owner = ownership_ir_active_event_owner_flag(
            e,
            source_name,
            value_form.span,
            .Store,
        )
    }
    if !has_owner {
        return value, false
    }
    value_ty, ok_value_ty := obvious_form_type(e, value_form)
    if !ok_value_ty || !ownership_type_has_destructor(e, value_ty) {
        return value, false
    }
    return managed_move_local_value_text(e, value_ty, value, owner_flag), true
}

immutable_def_mutation_error :: proc(e: ^Emitter, place: CST_Form) -> (Compile_Error, bool) {
    if place.kind != .Symbol {
        return {}, false
    }
    name := map_name(place.text)
    defer delete(name)
    if _, local := lookup_local_type(e, name); local {
        return {}, false
    }
    ensure_emitter_indexes(e)
    if idx, found := e.const_indices[name]; found {
        decl := &e.decls[idx]
        if !decl.const_decl.is_type_alias &&
           !decl.const_decl.is_overload {
            return Compile_Error{
                message = fmt.tprintf("cannot mutate immutable def %s; use defvar for mutable package state", place.text),
                span = place.span,
            }, true
        }
    }
    return {}, false
}
