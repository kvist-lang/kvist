package kvist

import "core:fmt"
import "core:strings"

// Result lifecycles are an internal compiler description of each value in a
// multi-result call. They deliberately are not part of Kvist's surface syntax:
// exact foreign bindings and wrapper bodies are the sources of truth.
Result_Lifecycle_Kind :: enum {
    Unknown,
    Borrowed,
    Owned_Delete,
    Owned_Custom,
    Owned_Managed,
}

Result_Cleanup_Condition :: Ownership_Activation

Result_Lifecycle :: struct {
    kind:            Result_Lifecycle_Kind,
    cleanup_head:    string,
    result_type:     string,
    condition:       Result_Cleanup_Condition,
    condition_index: int,
}

result_lifecycle_delete :: proc(lifecycle: ^Result_Lifecycle) {
    if lifecycle.cleanup_head != "" {
        delete(lifecycle.cleanup_head)
        lifecycle.cleanup_head = ""
    }
    if lifecycle.result_type != "" {
        delete(lifecycle.result_type)
        lifecycle.result_type = ""
    }
}

result_lifecycle_is_owned :: proc(lifecycle: Result_Lifecycle) -> bool {
    return lifecycle.kind == .Owned_Delete ||
           lifecycle.kind == .Owned_Custom ||
           lifecycle.kind == .Owned_Managed
}

result_lifecycles_match :: proc(left, right: Result_Lifecycle) -> bool {
    return left.kind == right.kind &&
           left.cleanup_head == right.cleanup_head &&
           left.result_type == right.result_type &&
           left.condition == right.condition &&
           left.condition_index == right.condition_index
}

result_symbol_maps_to_name :: proc(form: CST_Form, name: string) -> bool {
    if form.kind != .Symbol {
        return false
    }
    mapped := map_name(form.text)
    defer delete(mapped)
    return mapped == name
}

result_lifecycle_call_result_count :: proc(
    e: ^Emitter,
    form: CST_Form,
) -> (int, bool) {
    if e == nil ||
       form.kind != .List ||
       len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return 0, false
    }
    if _, proc_decl, ok_proc := resolve_proc_call_decl(e, form.items[0].text);
       ok_proc && proc_decl != nil && proc_decl.returns.kind == .Named {
        return len(proc_decl.returns.named), true
    }
    return ownership_imported_call_result_count(e, form.items[0].text)
}

form_has_owned_result_lifecycle :: proc(e: ^Emitter, form: CST_Form) -> bool {
    result_count, known_count := result_lifecycle_call_result_count(e, form)
    if !known_count {
        return false
    }
    for result_index := 0; result_index < result_count; result_index += 1 {
        lifecycle, known := infer_result_lifecycle(
            e,
            form,
            result_index,
            result_count,
        )
        if !known {
            continue
        }
        owned := result_lifecycle_is_owned(lifecycle)
        result_lifecycle_delete(&lifecycle)
        if owned {
            return true
        }
    }
    return false
}

known_foreign_result_lifecycle :: proc(
    e: ^Emitter,
    form: CST_Form,
    result_index, result_count: int,
) -> (Result_Lifecycle, bool) {
    if form.kind != .List ||
       len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return {}, false
    }
    head := form.items[0].text
    alias, _, ok_parts := imported_interop_call_parts(head)
    if !ok_parts {
        return {}, false
    }
    contract, known := ownership_imported_result_contract(
        e,
        head,
        result_index,
        result_count,
    )
    if !known {
        return {}, false
    }
    kind := Result_Lifecycle_Kind.Unknown
    #partial switch contract.result_flow {
    case .Borrowed:
        kind = .Borrowed
    case .Owned:
        kind = .Owned_Delete if contract.cleanup_kind == .Type_Default else .Owned_Custom
    }
    mapped_alias := map_name(alias)
    defer delete(mapped_alias)
    cleanup_head := ""
    if contract.cleanup_kind == .Call {
        cleanup_head = fmt.tprintf("%s.%s", mapped_alias, contract.cleanup_member)
    }
    return Result_Lifecycle{
        kind = kind,
        cleanup_head = cleanup_head,
        condition = contract.activation,
        condition_index = contract.activation_index,
    }, true
}

known_foreign_result_type :: proc(
    e: ^Emitter,
    form: CST_Form,
    result_index, result_count: int,
) -> (string, bool) {
    if form.kind != .List ||
       len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return "", false
    }
    head := form.items[0].text
    alias, _, ok_parts := imported_interop_call_parts(head)
    if !ok_parts {
        return "", false
    }
    contract, known := ownership_imported_result_contract(
        e,
        head,
        result_index,
        result_count,
    )
    if !known || contract.result_type == "" {
        return "", false
    }
    mapped_alias := map_name(alias)
    defer delete(mapped_alias)
    return qualify_imported_odin_type(mapped_alias, contract.result_type), true
}

infer_result_lifecycle :: proc(
    e: ^Emitter,
    form: CST_Form,
    result_index, result_count: int,
    depth: int = 0,
) -> (Result_Lifecycle, bool) {
    if depth > 16 || result_index < 0 || result_index >= result_count {
        return {}, false
    }
    if lifecycle, known := known_foreign_result_lifecycle(
        e,
        form,
        result_index,
        result_count,
    ); known {
        return lifecycle, true
    }
    if form.kind != .List ||
       len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return {}, false
    }
    head := form.items[0].text
    switch head {
    case "return":
        if len(form.items) != 2 {
            return {}, false
        }
        return infer_result_lifecycle(
            e,
            form.items[1],
            result_index,
            result_count,
            depth+1,
        )
    case "do", "block":
        if len(form.items) != 2 {
            return {}, false
        }
        return infer_result_lifecycle(
            e,
            form.items[1],
            result_index,
            result_count,
            depth+1,
        )
    case "if":
        if len(form.items) != 4 {
            return {}, false
        }
        then_lifecycle, then_known := infer_result_lifecycle(
            e,
            form.items[2],
            result_index,
            result_count,
            depth+1,
        )
        if !then_known {
            return {}, false
        }
        defer result_lifecycle_delete(&then_lifecycle)
        else_lifecycle, else_known := infer_result_lifecycle(
            e,
            form.items[3],
            result_index,
            result_count,
            depth+1,
        )
        if !else_known {
            return {}, false
        }
        if !result_lifecycles_match(then_lifecycle, else_lifecycle) {
            result_lifecycle_delete(&else_lifecycle)
            return {}, false
        }
        // Keep the else descriptor and release the duplicate above.
        return else_lifecycle, true
    }

    _, proc_decl, ok_proc := resolve_proc_call_decl(e, head)
    if !ok_proc ||
       proc_decl == nil ||
       proc_decl.returns.kind != .Named ||
       len(proc_decl.returns.named) != result_count {
        return {}, false
    }
    result_type := proc_decl.returns.named[result_index].ty
    if type_text_is_managed_value(e, result_type) {
        return Result_Lifecycle{
            kind = .Owned_Managed,
            result_type = strings.clone(result_type),
            condition = .Always,
            condition_index = -1,
        }, true
    }
    if len(proc_decl.body) != 1 {
        return {}, false
    }
    // Propagate only through a tail call/body whose returned value is itself
    // proven. This remains conservative for procedures with more complex
    // control flow or locally assembled result tuples.
    return infer_result_lifecycle(
        e,
        proc_decl.body[0],
        result_index,
        result_count,
        depth+1,
    )
}

result_params_shadow_name :: proc(params: []Param, name: string) -> bool {
    for param in params {
        mapped := map_name(param.name)
        shadows := mapped == name
        delete(mapped)
        if shadows {
            return true
        }
    }
    return false
}

result_form_references_name :: proc(form: CST_Form, name: string) -> bool {
    if result_symbol_maps_to_name(form, name) {
        return true
    }
    head, has_head := form_head_symbol_text(form)
    if has_head && (head == "quote" || head == "quasiquote") {
        return false
    }
    if has_head && head == "fn" {
        parsed, _, ok_parsed := parse_proc_literal_form(form)
        if !ok_parsed {
            return false
        }
        defer delete(parsed.params)
        defer delete(parsed.body)
        if result_params_shadow_name(parsed.params[:], name) {
            return false
        }
        for item in parsed.body {
            if result_form_references_name(item, name) {
                return true
            }
        }
        return false
    }
    if has_head && head == "let" && len(form.items) >= 3 {
        bindings, _, ok_bindings := parse_let_bindings(form.items[1])
        if !ok_bindings {
            return false
        }
        defer delete(bindings)
        for binding in bindings {
            if result_form_references_name(binding.value, name) {
                return true
            }
            if binding_declares_mapped_name(binding, name) {
                return false
            }
        }
        for item in form.items[2:] {
            if result_form_references_name(item, name) {
                return true
            }
        }
        return false
    }
    if form.kind != .List &&
       form.kind != .Vector &&
       form.kind != .Brace &&
       form.kind != .Set {
        return false
    }
    for item in form.items {
        if result_form_references_name(item, name) {
            return true
        }
    }
    return false
}

result_proc_literal_captures_name :: proc(form: CST_Form, name: string) -> bool {
    parsed, _, ok_parsed := parse_proc_literal_form(form)
    if !ok_parsed {
        return false
    }
    defer delete(parsed.params)
    defer delete(parsed.body)
    if result_params_shadow_name(parsed.params[:], name) {
        return false
    }
    for item in parsed.body {
        if result_form_references_name(item, name) {
            return true
        }
    }
    return false
}

form_contains_result_capture :: proc(form: CST_Form, name: string) -> bool {
    head, has_head := form_head_symbol_text(form)
    if has_head && (head == "quote" || head == "quasiquote") {
        return false
    }
    if has_head && head == "fn" {
        return result_proc_literal_captures_name(form, name)
    }
    if has_head && head == "let" && len(form.items) >= 3 {
        bindings, _, ok_bindings := parse_let_bindings(form.items[1])
        if !ok_bindings {
            return false
        }
        defer delete(bindings)
        for binding in bindings {
            if form_contains_result_capture(binding.value, name) {
                return true
            }
            if binding_declares_mapped_name(binding, name) {
                return false
            }
        }
        for item in form.items[2:] {
            if form_contains_result_capture(item, name) {
                return true
            }
        }
        return false
    }
    if form.kind != .List &&
       form.kind != .Vector &&
       form.kind != .Brace &&
       form.kind != .Set {
        return false
    }
    for item in form.items {
        if form_contains_result_capture(item, name) {
            return true
        }
    }
    return false
}

form_contains_result_storage :: proc(e: ^Emitter, form: CST_Form, name: string) -> bool {
    head, has_head := form_head_symbol_text(form)
    if has_head &&
       (head == "fn" || head == "quote" || head == "quasiquote") {
        return false
    }
    if has_head && head == "let" && len(form.items) >= 3 {
        bindings, _, ok_bindings := parse_let_bindings(form.items[1])
        if !ok_bindings {
            return false
        }
        defer delete(bindings)
        for binding in bindings {
            if form_contains_result_storage(e, binding.value, name) {
                return true
            }
            if binding_declares_mapped_name(binding, name) {
                return false
            }
        }
        for item in form.items[2:] {
            if form_contains_result_storage(e, item, name) {
                return true
            }
        }
        return false
    }
    if composite_literal_transfers_owned_name(e, form, name) {
        return true
    }
    if (form.kind == .Vector || form.kind == .Brace || form.kind == .Set) &&
       result_form_references_name(form, name) {
        return true
    }
    if has_head && head == "set!" && len(form.items) == 3 {
        replacement := form.items[2]
        if result_symbol_maps_to_name(replacement, name) ||
           composite_value_transfers_owned_name(e, replacement, name) {
            return true
        }
    }
    if form.kind != .List &&
       form.kind != .Vector &&
       form.kind != .Brace &&
       form.kind != .Set {
        return false
    }
    for item in form.items {
        if form_contains_result_storage(e, item, name) {
            return true
        }
    }
    return false
}

body_contains_result_capture :: proc(body: []CST_Form, name: string) -> bool {
    for form in body {
        if form_contains_result_capture(form, name) {
            return true
        }
    }
    return false
}

body_contains_result_storage :: proc(e: ^Emitter, body: []CST_Form, name: string) -> bool {
    for form in body {
        if form_contains_result_storage(e, form, name) {
            return true
        }
    }
    return false
}

form_contains_potential_owned_transfer :: proc(
    e: ^Emitter,
    form: CST_Form,
    name: string,
    can_transfer_final: bool = false,
) -> bool {
    if can_transfer_final && result_symbol_maps_to_name(form, name) {
        return true
    }
    if can_transfer_final && composite_value_transfers_owned_name(e, form, name) {
        return true
    }
    if form_is_delete_of_name(form, name) {
        return true
    }
    head, has_head := form_head_symbol_text(form)
    if has_head && (head == "quote" || head == "quasiquote") {
        return false
    }
    if has_head && head == "fn" {
        return result_proc_literal_captures_name(form, name)
    }
    if form_contains_result_storage(e, form, name) {
        return true
    }
    if has_head && head == "let" && len(form.items) >= 3 {
        if bindings, _, ok_bindings := parse_let_bindings(form.items[1]); ok_bindings {
            defer delete(bindings)
            for binding in bindings {
                if result_symbol_maps_to_name(binding.value, name) {
                    return true
                }
                if form_contains_potential_owned_transfer(e, binding.value, name) {
                    return true
                }
                if binding_declares_mapped_name(binding, name) {
                    return false
                }
            }
        }
        for item, idx in form.items[2:] {
            if form_contains_potential_owned_transfer(
                e,
                item,
                name,
                can_transfer_final && idx == len(form.items[2:])-1,
            ) {
                return true
            }
        }
        return false
    }
    if has_head && (head == "do" || head == "block") {
        for item, idx in form.items[1:] {
            if form_contains_potential_owned_transfer(
                e,
                item,
                name,
                can_transfer_final && idx == len(form.items[1:])-1,
            ) {
                return true
            }
        }
        return false
    }
    if has_head && head == "if" && len(form.items) >= 3 {
        if form_contains_potential_owned_transfer(e, form.items[1], name) {
            return true
        }
        for item in form.items[2:] {
            if form_contains_potential_owned_transfer(
                e,
                item,
                name,
                can_transfer_final,
            ) {
                return true
            }
        }
        return false
    }
    if has_head && head == "return" {
        for item in form.items[1:] {
            if result_symbol_maps_to_name(item, name) {
                return true
            }
            if composite_literal_transfers_owned_name(e, item, name) {
                return true
            }
        }
    }
    if has_head && form_transfers_owned_args(form) {
        for item in form.items[2:] {
            if result_symbol_maps_to_name(item, name) {
                return true
            }
        }
    }
    if has_head {
        for item, item_index in form.items[1:] {
            if result_symbol_maps_to_name(item, name) &&
               (call_arg_targets_owned_param(e, form, item_index+1) ||
                call_arg_transfers_owned_result(e, form, item_index+1)) {
                return true
            }
        }
    }
    if form.kind != .List &&
       form.kind != .Vector &&
       form.kind != .Brace &&
       form.kind != .Set {
        return false
    }
    for item in form.items {
        if form_contains_potential_owned_transfer(e, item, name) {
            return true
        }
    }
    return false
}

body_contains_potential_owned_transfer :: proc(
    e: ^Emitter,
    body: []CST_Form,
    name: string,
) -> bool {
    for form, idx in body {
        if form_contains_potential_owned_transfer(
            e,
            form,
            name,
            idx == len(body)-1,
        ) {
            return true
        }
    }
    return false
}

later_bindings_contain_result_capture :: proc(
    bindings: []Binding,
    binding_index: int,
    name: string,
) -> bool {
    for later_index := binding_index + 1; later_index < len(bindings); later_index += 1 {
        later := bindings[later_index]
        if form_contains_result_capture(later.value, name) {
            return true
        }
        if binding_declares_mapped_name(later, name) {
            return false
        }
    }
    return false
}

later_bindings_contain_result_storage :: proc(
    e: ^Emitter,
    bindings: []Binding,
    binding_index: int,
    name: string,
) -> bool {
    for later_index := binding_index + 1; later_index < len(bindings); later_index += 1 {
        later := bindings[later_index]
        if form_contains_result_storage(e, later.value, name) {
            return true
        }
        if binding_declares_mapped_name(later, name) {
            return false
        }
    }
    return false
}

automatic_result_cleanup_skip_reason :: proc(
    e: ^Emitter,
    bindings: []Binding,
    binding_index: int,
    body: []CST_Form,
    name: string,
) -> Ownership_IR_Cleanup_Skip_Reason {
    if name == "" ||
       later_binding_aliases_name(bindings, binding_index, name) ||
       body_assigns_name(body, name) ||
       body_deletes_or_returns_name(e, body, name, true) {
        return .None
    }
    if later_bindings_contain_result_capture(bindings, binding_index, name) ||
       body_contains_result_capture(body, name) {
        return .Captured_By_Closure
    }
    if later_bindings_contain_result_storage(e, bindings, binding_index, name) ||
       body_contains_result_storage(e, body, name) {
        return .Stored_Or_Mutable
    }
    return .None
}

later_binding_aliases_name :: proc(
    bindings: []Binding,
    binding_index: int,
    name: string,
) -> bool {
    for later_index := binding_index + 1; later_index < len(bindings); later_index += 1 {
        later := bindings[later_index]
        if result_symbol_maps_to_name(later.value, name) {
            return true
        }
        if binding_declares_mapped_name(later, name) {
            return false
        }
    }
    return false
}

destructured_result_cleanup_is_safe :: proc(
    e: ^Emitter,
    bindings: []Binding,
    binding_index: int,
    body: []CST_Form,
    name: string,
) -> bool {
    return name != "" &&
           !later_binding_aliases_name(bindings, binding_index, name) &&
           !later_bindings_transfer_name(e, bindings, binding_index, name) &&
           !body_assigns_name(body, name) &&
           !body_deletes_or_returns_name(e, body, name, true) &&
           !body_contains_potential_owned_transfer(e, body, name)
}

result_lifecycle_condition_is_stable :: proc(
    lifecycle: Result_Lifecycle,
    pattern: []string,
    body: []CST_Form,
) -> bool {
    if lifecycle.condition == .Always {
        return true
    }
    if lifecycle.condition_index < 0 ||
       lifecycle.condition_index >= len(pattern) ||
       pattern[lifecycle.condition_index] == "" {
        return false
    }
    return !body_assigns_name(body, pattern[lifecycle.condition_index])
}

result_lifecycle_activation_text :: proc(
    lifecycle: Result_Lifecycle,
    pattern: []string,
) -> (string, bool) {
    if lifecycle.condition == .Always {
        return "true", true
    }
    if lifecycle.condition_index < 0 ||
       lifecycle.condition_index >= len(pattern) ||
       pattern[lifecycle.condition_index] == "" {
        return "", false
    }
    #partial switch lifecycle.condition {
    case .Sibling_Nil:
        return fmt.tprintf(
            "%s == nil",
            pattern[lifecycle.condition_index],
        ), true
    case .Sibling_True:
        return fmt.tprintf("%s", pattern[lifecycle.condition_index]), true
    case .Always:
        return "true", true
    }
    return "", false
}

emit_result_lifecycle_cleanup :: proc(
    e: ^Emitter,
    lifecycle: Result_Lifecycle,
    pattern: []string,
    result_index: int,
) {
    if !result_lifecycle_is_owned(lifecycle) ||
       result_index < 0 ||
       result_index >= len(pattern) ||
       pattern[result_index] == "" {
        return
    }
    cleanup := ""
    #partial switch lifecycle.kind {
    case .Owned_Delete:
        cleanup = fmt.tprintf("delete(%s)", pattern[result_index])
    case .Owned_Custom:
        if lifecycle.cleanup_head == "" {
            return
        }
        cleanup = fmt.tprintf(
            "%s(%s)",
            lifecycle.cleanup_head,
            pattern[result_index],
        )
    case .Owned_Managed:
        if lifecycle.result_type == "" {
            return
        }
        cleanup = managed_destroy_value_text(
            e,
            lifecycle.result_type,
            pattern[result_index],
        )
    case:
        return
    }
    defer delete(cleanup)

    if lifecycle.condition == .Always {
        emit_line(e, fmt.tprintf("defer %s", cleanup))
        return
    }
    condition, ok_condition := result_lifecycle_activation_text(
        lifecycle,
        pattern,
    )
    if !ok_condition {
        return
    }
    defer delete(condition)
    emit_line(e, "defer {")
    e.indent += 1
    emit_line(e, fmt.tprintf("if %s {{", condition))
    e.indent += 1
    emit_line(e, cleanup)
    e.indent -= 1
    emit_line(e, "}")
    e.indent -= 1
    emit_line(e, "}")
}
