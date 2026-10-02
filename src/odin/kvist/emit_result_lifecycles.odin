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

// Call contracts are the canonical source for opaque foreign ownership. This
// is the only conversion from their public flow/cleanup vocabulary to the
// emitter's concrete per-result lifecycle.
ownership_result_lifecycle_from_call_contract :: proc(
    contract: Ownership_Call_Contract,
    mapped_alias: string,
) -> (Result_Lifecycle, bool) {
    lifecycle := Result_Lifecycle{
        condition = contract.activation,
        condition_index = contract.activation_index,
    }
    #partial switch contract.result_flow {
    case .Borrowed:
        if contract.cleanup_kind != .None {
            return {}, false
        }
        lifecycle.kind = .Borrowed
    case .Owned:
        #partial switch contract.cleanup_kind {
        case .Type_Default:
            lifecycle.kind = .Owned_Delete
        case .Call:
            if mapped_alias == "" || contract.cleanup_member == "" {
                return {}, false
            }
            lifecycle.kind = .Owned_Custom
            lifecycle.cleanup_head = fmt.aprintf(
                "%s.%s",
                mapped_alias,
                contract.cleanup_member,
            )
        case .None:
            return {}, false
        }
    case .Unknown:
        return {}, false
    }
    if contract.result_type != "" {
        lifecycle.result_type = qualify_imported_odin_type(
            mapped_alias,
            contract.result_type,
        )
    }
    return lifecycle, true
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
    mapped_alias := map_name(alias)
    defer delete(mapped_alias)
    return ownership_result_lifecycle_from_call_contract(
        contract,
        mapped_alias,
    )
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

infer_result_lifecycle_from_let_binding :: proc(
    e: ^Emitter,
    form: CST_Form,
    bindings: []Binding,
    depth: int,
) -> (Result_Lifecycle, bool) {
    if depth > 16 || form.kind != .Symbol {
        return {}, false
    }
    name := map_name(form.text)
    defer delete(name)
    for binding_index := len(bindings)-1;
        binding_index >= 0;
        binding_index -= 1 {
        binding := bindings[binding_index]
        for pattern_name, pattern_index in binding.pattern {
            mapped_pattern := map_name(pattern_name)
            matches := mapped_pattern == name
            delete(mapped_pattern)
            if !matches {
                continue
            }
            return infer_result_lifecycle(
                e,
                binding.value,
                pattern_index,
                len(binding.pattern),
                depth+1,
            )
        }
        if binding.name == "" {
            continue
        }
        mapped_binding := map_name(binding.name)
        matches := mapped_binding == name
        delete(mapped_binding)
        if !matches {
            continue
        }
        if binding.value.kind == .Symbol {
            return infer_result_lifecycle_from_let_binding(
                e,
                binding.value,
                bindings[:binding_index],
                depth+1,
            )
        }
        return infer_result_lifecycle(
            e,
            binding.value,
            0,
            1,
            depth+1,
        )
    }
    return {}, false
}

Result_Lifecycle_Binding_Origin :: struct {
    binding_index: int,
    result_index:  int,
}

result_lifecycle_let_binding_origin :: proc(
    form: CST_Form,
    bindings: []Binding,
    depth: int,
) -> (Result_Lifecycle_Binding_Origin, bool) {
    if depth > 16 || form.kind != .Symbol {
        return {}, false
    }
    name := map_name(form.text)
    defer delete(name)
    for binding_index := len(bindings)-1;
        binding_index >= 0;
        binding_index -= 1 {
        binding := bindings[binding_index]
        for pattern_name, pattern_index in binding.pattern {
            mapped_pattern := map_name(pattern_name)
            matches := mapped_pattern == name
            delete(mapped_pattern)
            if matches {
                return Result_Lifecycle_Binding_Origin{
                    binding_index = binding_index,
                    result_index = pattern_index,
                }, true
            }
        }
        if binding.name == "" {
            continue
        }
        mapped_binding := map_name(binding.name)
        matches := mapped_binding == name
        delete(mapped_binding)
        if !matches {
            continue
        }
        if binding.value.kind == .Symbol {
            return result_lifecycle_let_binding_origin(
                binding.value,
                bindings[:binding_index],
                depth+1,
            )
        }
        return Result_Lifecycle_Binding_Origin{
            binding_index = binding_index,
            result_index = 0,
        }, true
    }
    return {}, false
}

result_form_contains_return :: proc(form: CST_Form, depth: int = 0) -> bool {
    if depth > 32 || form.kind != .List || len(form.items) == 0 {
        return false
    }
    if form.items[0].kind == .Symbol {
        switch form.items[0].text {
        case "return":
            return true
        case "fn", "quote", "quasiquote", "comment":
            return false
        }
    }
    for item in form.items[1:] {
        if result_form_contains_return(item, depth+1) {
            return true
        }
    }
    return false
}

infer_result_lifecycle_from_let_tail :: proc(
    e: ^Emitter,
    form: CST_Form,
    bindings: []Binding,
    result_index, result_count, depth: int,
    intervening_forms: []CST_Form = nil,
) -> (Result_Lifecycle, bool) {
    if depth > 16 {
        return {}, false
    }
    if form.kind == .Symbol {
        return infer_result_lifecycle_from_let_binding(
            e,
            form,
            bindings,
            depth+1,
        )
    }
    if form.kind != .List || len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return {}, false
    }
    head := form.items[0].text
    switch head {
    case "return":
        if len(form.items) == result_count+1 {
            lifecycle, known := infer_result_lifecycle_from_let_tail(
                e,
                form.items[result_index+1],
                bindings,
                0,
                1,
                depth+1,
            )
            if !known || lifecycle.condition == .Always {
                return lifecycle, known
            }
            value_origin, known_origin :=
                result_lifecycle_let_binding_origin(
                    form.items[result_index+1],
                    bindings,
                    depth+1,
                )
            if !known_origin ||
               value_origin.binding_index < 0 ||
               value_origin.binding_index >= len(bindings) {
                result_lifecycle_delete(&lifecycle)
                return {}, false
            }
            source_binding := bindings[value_origin.binding_index]
            if lifecycle.condition_index < 0 ||
               lifecycle.condition_index >= len(source_binding.pattern) {
                result_lifecycle_delete(&lifecycle)
                return {}, false
            }
            condition_origin := Result_Lifecycle_Binding_Origin{
                binding_index = value_origin.binding_index,
                result_index = lifecycle.condition_index,
            }
            source_condition_name := map_name(
                source_binding.pattern[lifecycle.condition_index],
            )
            source_condition_mutated := body_may_mutate_name(
                intervening_forms,
                source_condition_name,
            )
            delete(source_condition_name)
            if source_condition_mutated {
                result_lifecycle_delete(&lifecycle)
                return {}, false
            }
            for returned_form, returned_index in form.items[1:] {
                returned_origin, known_returned_origin :=
                    result_lifecycle_let_binding_origin(
                        returned_form,
                        bindings,
                        depth+1,
                    )
                if known_returned_origin &&
                   returned_origin == condition_origin {
                    returned_condition_name := map_name(returned_form.text)
                    returned_condition_mutated := body_may_mutate_name(
                        intervening_forms,
                        returned_condition_name,
                    )
                    delete(returned_condition_name)
                    if returned_condition_mutated {
                        result_lifecycle_delete(&lifecycle)
                        return {}, false
                    }
                    lifecycle.condition_index = returned_index
                    return lifecycle, true
                }
            }
            result_lifecycle_delete(&lifecycle)
            return {}, false
        }
    case "do", "block":
        if len(form.items) > 1 {
            for prefix_form in form.items[1:len(form.items)-1] {
                if result_form_contains_return(prefix_form) {
                    return {}, false
                }
            }
            scoped_intervening: [dynamic]CST_Form
            defer delete(scoped_intervening)
            append(&scoped_intervening, ..intervening_forms)
            append(
                &scoped_intervening,
                ..form.items[1:len(form.items)-1],
            )
            return infer_result_lifecycle_from_let_tail(
                e,
                form.items[len(form.items)-1],
                bindings,
                result_index,
                result_count,
                depth+1,
                scoped_intervening[:],
            )
        }
    case "if":
        if len(form.items) == 4 {
            if result_form_contains_return(form.items[1]) {
                return {}, false
            }
            scoped_intervening: [dynamic]CST_Form
            defer delete(scoped_intervening)
            append(&scoped_intervening, ..intervening_forms)
            append(&scoped_intervening, form.items[1])
            then_lifecycle, then_known :=
                infer_result_lifecycle_from_let_tail(
                    e,
                    form.items[2],
                    bindings,
                    result_index,
                    result_count,
                    depth+1,
                    scoped_intervening[:],
                )
            if !then_known {
                return {}, false
            }
            defer result_lifecycle_delete(&then_lifecycle)
            else_lifecycle, else_known :=
                infer_result_lifecycle_from_let_tail(
                    e,
                    form.items[3],
                    bindings,
                    result_index,
                    result_count,
                    depth+1,
                    scoped_intervening[:],
                )
            if !else_known {
                return {}, false
            }
            if !result_lifecycles_match(
                then_lifecycle,
                else_lifecycle,
            ) {
                result_lifecycle_delete(&else_lifecycle)
                return {}, false
            }
            return else_lifecycle, true
        }
    case "let":
        if len(form.items) >= 3 {
            nested_bindings, _, ok_bindings :=
                parse_let_bindings(form.items[1])
            if !ok_bindings {
                return {}, false
            }
            defer delete(nested_bindings)
            for binding in nested_bindings {
                if result_form_contains_return(binding.value) {
                    return {}, false
                }
            }
            for prefix_form in form.items[2:len(form.items)-1] {
                if result_form_contains_return(prefix_form) {
                    return {}, false
                }
            }
            scoped_bindings: [dynamic]Binding
            defer delete(scoped_bindings)
            append(&scoped_bindings, ..bindings)
            append(&scoped_bindings, ..nested_bindings[:])
            scoped_intervening: [dynamic]CST_Form
            defer delete(scoped_intervening)
            append(&scoped_intervening, ..intervening_forms)
            for binding in nested_bindings {
                append(&scoped_intervening, binding.value)
            }
            append(
                &scoped_intervening,
                ..form.items[2:len(form.items)-1],
            )
            return infer_result_lifecycle_from_let_tail(
                e,
                form.items[len(form.items)-1],
                scoped_bindings[:],
                result_index,
                result_count,
                depth+1,
                scoped_intervening[:],
            )
        }
    }
    return infer_result_lifecycle(
        e,
        form,
        result_index,
        result_count,
        depth+1,
    )
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
    if result_index == 0 &&
       (form_is_owned_alloc_call(form, .String, e) ||
        form_is_owned_alloc_call(form, .Bytes, e) ||
        form_is_owned_alloc_call(form, .Slice, e)) {
        return Result_Lifecycle{
            kind = .Owned_Delete,
            condition = .Always,
            condition_index = -1,
        }, true
    }
    if form.kind != .List ||
       len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return {}, false
    }
    head := form.items[0].text
    switch head {
    case "return":
        if len(form.items) == 2 {
            return infer_result_lifecycle(
                e,
                form.items[1],
                result_index,
                result_count,
                depth+1,
            )
        }
        if len(form.items) == result_count+1 {
            lifecycle, known := infer_result_lifecycle(
                e,
                form.items[result_index+1],
                0,
                1,
                depth+1,
            )
            if known && lifecycle.condition != .Always {
                result_lifecycle_delete(&lifecycle)
                return {}, false
            }
            return lifecycle, known
        }
        return {}, false
    case "do", "block":
        if len(form.items) < 2 {
            return {}, false
        }
        for prefix_form in form.items[1:len(form.items)-1] {
            if result_form_contains_return(prefix_form) {
                return {}, false
            }
        }
        return infer_result_lifecycle(
            e,
            form.items[len(form.items)-1],
            result_index,
            result_count,
            depth+1,
        )
    case "if":
        if len(form.items) != 4 {
            return {}, false
        }
        if result_form_contains_return(form.items[1]) {
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
    case "let":
        if len(form.items) < 3 {
            return {}, false
        }
        bindings, _, ok_bindings := parse_let_bindings(form.items[1])
        if !ok_bindings {
            return {}, false
        }
        defer delete(bindings)
        for binding in bindings {
            if result_form_contains_return(binding.value) {
                return {}, false
            }
        }
        for prefix_form in form.items[2:len(form.items)-1] {
            if result_form_contains_return(prefix_form) {
                return {}, false
            }
        }
        intervening_forms: [dynamic]CST_Form
        defer delete(intervening_forms)
        for binding in bindings {
            append(&intervening_forms, binding.value)
        }
        append(
            &intervening_forms,
            ..form.items[2:len(form.items)-1],
        )
        return infer_result_lifecycle_from_let_tail(
            e,
            form.items[len(form.items)-1],
            bindings[:],
            result_index,
            result_count,
            depth+1,
            intervening_forms[:],
        )
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
    if len(proc_decl.body) == 0 {
        return {}, false
    }
    for prefix_form in proc_decl.body[:len(proc_decl.body)-1] {
        if result_form_contains_return(prefix_form) {
            return {}, false
        }
    }
    // Propagate through a proven tail value. Prefix forms are safe only when
    // they cannot return an alternate ownership shape.
    return infer_result_lifecycle(
        e,
        proc_decl.body[len(proc_decl.body)-1],
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
    return !body_may_mutate_name(body, pattern[lifecycle.condition_index])
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

emit_result_lifecycle_immediate_cleanup :: proc(
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
        emit_line(e, cleanup)
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
    emit_line(e, fmt.tprintf("if %s {{", condition))
    e.indent += 1
    emit_line(e, cleanup)
    e.indent -= 1
    emit_line(e, "}")
}
