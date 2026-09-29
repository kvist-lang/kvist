package kvist

import "core:fmt"
import "core:os"
import "core:strings"
import "core:time"

owned_warning_subject :: proc(form: CST_Form) -> string {
    if head, ok := form_head_symbol_text(form); ok {
        return display_head_name(head)
    }
    #partial switch form.kind {
    case .Vector:
        return "vector literal"
    case .Brace:
        return "map literal"
    case .Set:
        return "set literal"
    case:
        return "owned value"
    }
}

discarded_result_has_automatic_cleanup :: proc(e: ^Emitter, form: CST_Form) -> bool {
    if e == nil ||
       form.kind != .List ||
       len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return false
    }
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

nested_owned_result_error_message :: proc(form: CST_Form) -> string {
    subject := owned_warning_subject(form)
    if subject == "owned value" {
        return "owned result must be bound or returned; nested owned results would leak"
    }
    return fmt.tprintf("%s returns an owned result; bind it so it can be cleaned up, or return it to transfer ownership", subject)
}

form_is_struct_or_union_constructor :: proc(e: ^Emitter, form: CST_Form) -> bool {
    if form.kind != .List || len(form.items) == 0 || form.items[0].kind != .Symbol {
        return false
    }

    head_name := map_name(form.items[0].text)
    defer delete(head_name)
    if e != nil {
        if _, ok_struct := find_struct_decl(e, head_name); ok_struct {
            return true
        }
        if _, ok_union := find_union_decl(e, head_name); ok_union {
            return true
        }
    }

    return (len(head_name) > 0 && head_name[0] >= 'A' && head_name[0] <= 'Z') ||
           dotted_head_member_starts_upper(head_name)
}

composite_value_transfers_owned_name :: proc(e: ^Emitter, form: CST_Form, name: string) -> bool {
    if form.kind == .Symbol {
        return map_name(form.text) == name
    }
    if form.kind == .Vector || form.kind == .Set {
        for item in form.items {
            if composite_value_transfers_owned_name(e, item, name) {
                return true
            }
        }
        return false
    }
    return composite_literal_transfers_owned_name(e, form, name)
}

composite_literal_transfers_owned_name :: proc(e: ^Emitter, form: CST_Form, name: string) -> bool {
    if !form_is_struct_or_union_constructor(e, form) {
        return false
    }
    args := form.items[1:]
    if keyword_arg_tail_is_syntax(args, 0) {
        for i := 1; i < len(args); i += 2 {
            if composite_value_transfers_owned_name(e, args[i], name) {
                return true
            }
        }
        return false
    }
    for arg in args {
        if composite_value_transfers_owned_name(e, arg, name) {
            return true
        }
    }
    return false
}

form_head_symbol_text :: proc(form: CST_Form) -> (string, bool) {
    if form.kind != .List || len(form.items) == 0 || form.items[0].kind != .Symbol {
        return "", false
    }
    return form.items[0].text, true
}

cleanup_call_head :: proc(head: string) -> bool {
    normalized := map_name(head)
    defer delete(normalized)
    return strings.contains(normalized, "destroy") ||
           strings.contains(normalized, "free") ||
           strings.contains(normalized, "close") ||
           strings.contains(normalized, "release")
}

cleanup_arg_names_value :: proc(form: CST_Form, name: string) -> bool {
    if form.kind == .Symbol {
        return map_name(form.text) == name
    }
    head, ok := form_head_symbol_text(form)
    if ok && (head == "addr" || head == "deref") && len(form.items) == 2 {
        return cleanup_arg_names_value(form.items[1], name)
    }
    return false
}

form_is_delete_of_name :: proc(form: CST_Form, name: string) -> bool {
    head, ok := form_head_symbol_text(form)
    if !ok {
        return false
    }
    if head == "delete" && len(form.items) == 2 && form.items[1].kind == .Symbol {
        return map_name(form.items[1].text) == name
    }
    if cleanup_call_head(head) {
        for item in form.items[1:] {
            if cleanup_arg_names_value(item, name) {
                return true
            }
        }
    }
    if head == "defer" {
        for item in form.items[1:] {
            if form_is_delete_of_name(item, name) {
                return true
            }
        }
    }
    return false
}

body_deletes_name :: proc(forms: []CST_Form, name: string) -> bool {
    for form in forms {
        if form_contains_delete_of_name(form, name) {
            return true
        }
    }
    return false
}

form_assigns_name :: proc(form: CST_Form, name: string) -> bool {
    if form.kind != .List &&
       form.kind != .Vector &&
       form.kind != .Brace &&
       form.kind != .Set {
        return false
    }
    if form.kind == .List && len(form.items) > 0 && form.items[0].kind == .Symbol {
        head := form.items[0].text
        if head == "fn" || head == "quote" || head == "quasiquote" {
            return false
        }
        if head == "set!" &&
           len(form.items) == 3 &&
           form.items[1].kind == .Symbol {
            target := map_name(form.items[1].text)
            matches := target == name
            delete(target)
            if matches {
                return true
            }
        }
    }
    for item in form.items {
        if form_assigns_name(item, name) {
            return true
        }
    }
    return false
}

body_assigns_name :: proc(forms: []CST_Form, name: string) -> bool {
    for form in forms {
        if form_assigns_name(form, name) {
            return true
        }
    }
    return false
}

later_bindings_transfer_name :: proc(
    e: ^Emitter,
    bindings: []Binding,
    binding_index: int,
    name: string,
) -> bool {
    for later_index := binding_index + 1; later_index < len(bindings); later_index += 1 {
        later := bindings[later_index]
        if form_transfers_owned_name(e, later.value, name, false) ||
           composite_literal_transfers_owned_name(e, later.value, name) {
            return true
        }
        if binding_declares_mapped_name(later, name) {
            return false
        }
    }
    return false
}

form_contains_delete_of_name :: proc(form: CST_Form, name: string) -> bool {
    if form_is_delete_of_name(form, name) {
        return true
    }
    if form.kind != .List &&
       form.kind != .Vector &&
       form.kind != .Brace &&
       form.kind != .Set {
        return false
    }
    if form.kind == .List &&
       len(form.items) > 0 &&
       form.items[0].kind == .Symbol &&
       (form.items[0].text == "fn" ||
        form.items[0].text == "quote" ||
        form.items[0].text == "quasiquote") {
        return false
    }
    for item in form.items {
        if form_contains_delete_of_name(item, name) {
            return true
        }
    }
    return false
}

form_direct_borrow_owner_name :: proc(form: CST_Form, e: ^Emitter = nil) -> (string, bool) {
    if !form_is_borrowed_view_result(form, e) || form.kind != .List || len(form.items) < 2 {
        return "", false
    }
    head, ok_head := form_head_symbol_text(form)
    if !ok_head {
        return "", false
    }
    owner_idx := 1
    if proc_decl, ok_proc := proc_decl_borrowed_view_decl(e, head); ok_proc {
        if idx, ok_idx := proc_decl_borrow_owner_arg_index(proc_decl); ok_idx {
            owner_idx = idx + 1
        }
    }
    if owner_idx < len(form.items) && form.items[owner_idx].kind == .Symbol {
        return map_name(form.items[owner_idx].text), true
    }
    return "", false
}

form_transfers_owned_args :: proc(form: CST_Form) -> bool {
    head, ok := form_head_symbol_text(form)
    if !ok {
        return false
    }
    switch head {
    case "append":
        return true
    }
    return false
}

proc_decl_transfers_param_in_result :: proc(e: ^Emitter, proc_decl: ^Proc_Decl, param_index: int) -> bool {
    if proc_decl == nil ||
       param_index < 0 ||
       param_index >= len(proc_decl.params) ||
       len(proc_decl.body) == 0 {
        return false
    }
    name := map_name(proc_decl.params[param_index].name)
    defer delete(name)
    return form_transfers_owned_name(e, proc_decl.body[len(proc_decl.body)-1], name, true)
}

call_arg_targets_owned_param :: proc(e: ^Emitter, form: CST_Form, arg_index: int) -> bool {
    if e == nil ||
       form.kind != .List ||
       len(form.items) == 0 ||
       form.items[0].kind != .Symbol ||
       arg_index <= 0 {
        return false
    }
    _, proc_decl, ok_proc := resolve_proc_call_decl(e, form.items[0].text)
    if !ok_proc || proc_decl == nil || arg_index-1 >= len(proc_decl.params) {
        return false
    }
    return proc_decl.params[arg_index-1].ownership == .Owned
}

call_arg_transfers_owned_result :: proc(e: ^Emitter, form: CST_Form, arg_index: int) -> bool {
    if e == nil ||
       form.kind != .List ||
       len(form.items) == 0 ||
       form.items[0].kind != .Symbol ||
       arg_index <= 0 {
        return false
    }
    name := map_name(form.items[0].text)
    defer delete(name)
    proc_decl, ok := find_proc_decl(e, name)
    if ok {
        if arg_index-1 < len(proc_decl.params) &&
           proc_decl.params[arg_index-1].ownership == .Owned {
            return true
        }
        return proc_decl_transfers_param_in_result(e, proc_decl, arg_index-1)
    }
    overload_decl, ok_overload := find_overload_decl(e, name)
    if !ok_overload {
        return false
    }
    param_index := arg_index-1
    applicable := 0
    for member in overload_decl.overload_members {
        member_decl, ok_member := find_proc_decl(e, member)
        if !ok_member ||
           !proc_accepts_positional_arg_count(member_decl, len(form.items)-1) ||
           param_index >= len(member_decl.params) {
            continue
        }
        applicable += 1
        if member_decl.params[param_index].ownership != .Owned &&
           !proc_decl_transfers_param_in_result(e, member_decl, param_index) {
            return false
        }
    }
    return applicable > 0
}

binding_declares_mapped_name :: proc(binding: Binding, name: string) -> bool {
    names: [dynamic]string
    defer delete(names)
    binding_declared_names_append(binding, &names)
    return binding_names_contain(names[:], name)
}

let_scope_transfers_owned_name :: proc(
    e: ^Emitter,
    bindings: []Binding,
    body: []CST_Form,
    name: string,
    can_transfer_final: bool,
) -> bool {
    for binding in bindings {
        // A binding value is evaluated before its target enters scope, so an
        // explicit delete or return here still refers to the outer binding.
        // A bare final symbol only moves into the new local and is not, by
        // itself, proof that the value is eventually cleaned up.
        if form_transfers_owned_name(e, binding.value, name, false) {
            return true
        }
        if binding_declares_mapped_name(binding, name) {
            return false
        }
    }
    return body_deletes_or_returns_name(e, body, name, can_transfer_final)
}

type_case_transfers_owned_name :: proc(e: ^Emitter, form: CST_Form, name: string, can_transfer_final: bool) -> bool {
    if len(form.items) < 5 || len(form.items)%2 == 0 {
        return false
    }
    for i := 2; i < len(form.items)-1; i += 2 {
        _, binding, ignored, _, ok_pattern :=
            case_type_payload_pattern(form.items[i])
        if !ok_pattern || (!ignored && binding == name) {
            return false
        }
        if !form_transfers_owned_name(e, form.items[i+1], name, can_transfer_final) {
            return false
        }
    }
    return form_transfers_owned_name(
        e,
        form.items[len(form.items)-1],
        name,
        can_transfer_final,
    )
}

form_transfers_owned_name :: proc(e: ^Emitter, form: CST_Form, name: string, can_transfer_final: bool) -> bool {
    if form_is_delete_of_name(form, name) {
        return true
    }

    head, ok := form_head_symbol_text(form)
    if ok && head == "return" {
        for item in form.items[1:] {
            if item.kind == .Symbol && map_name(item.text) == name {
                return true
            }
            if composite_literal_transfers_owned_name(e, item, name) {
                return true
            }
        }
    }

    if ok && form_transfers_owned_args(form) {
        for item in form.items[2:] {
            if item.kind == .Symbol && map_name(item.text) == name {
                return true
            }
        }
    }

    if ok && e != nil {
        for item, item_index in form.items[1:] {
            if item.kind == .Symbol &&
               map_name(item.text) == name &&
               call_arg_targets_owned_param(e, form, item_index+1) {
                return true
            }
        }
    }

    if ok && head == "let" && len(form.items) >= 3 {
        bindings, _, ok_bindings := parse_let_bindings(form.items[1])
        if !ok_bindings {
            return false
        }
        defer delete(bindings)
        return let_scope_transfers_owned_name(
            e,
            bindings[:],
            form.items[2:],
            name,
            can_transfer_final,
        )
    }

    if ok && head == "do" && len(form.items) >= 2 {
        return body_deletes_or_returns_name(e, form.items[1:], name, can_transfer_final)
    }

    if ok && head == "if" {
        if len(form.items) < 4 {
            return false
        }
        return form_transfers_owned_name(e, form.items[2], name, can_transfer_final) &&
            form_transfers_owned_name(e, form.items[3], name, can_transfer_final)
    }

    if ok && head == "type-case" {
        return type_case_transfers_owned_name(e, form, name, can_transfer_final)
    }

    if ok && head == "match" {
        if len(form.items) < 4 {
            return false
        }
        for i := 2; i+1 < len(form.items); i += 2 {
            names: [dynamic]string
            _, ok_pattern := validate_match_pattern(form.items[i], &names)
            shadows_name := binding_names_contain(names[:], name)
            delete(names)
            if !ok_pattern || shadows_name {
                return false
            }
            if !form_transfers_owned_name(e, form.items[i+1], name, can_transfer_final) {
                return false
            }
        }
        return true
    }

    if can_transfer_final && form.kind == .Symbol && map_name(form.text) == name {
        return true
    }

    if can_transfer_final && composite_literal_transfers_owned_name(e, form, name) {
        return true
    }

    return false
}

body_deletes_or_returns_name :: proc(e: ^Emitter, forms: []CST_Form, name: string, can_transfer_final: bool) -> bool {
    for form, idx in forms {
        if form_transfers_owned_name(e, form, name, can_transfer_final && idx == len(forms)-1) {
            return true
        }
    }
    return false
}

form_all_explicit_managed_returns_owned :: proc(
    e: ^Emitter,
    form: CST_Form,
    return_ty: string,
    depth: int = 0,
) -> bool {
    if depth > 16 || form.kind != .List || len(form.items) == 0 {
        return true
    }
    if form.items[0].kind == .Symbol {
        switch form.items[0].text {
        case "return":
            if len(form.items) != 2 {
                return false
            }
            return form_produces_owned_managed_type(e, form.items[1], return_ty)
        case "fn", "quote", "quasiquote":
            return true
        }
    }
    for item in form.items[1:] {
        if !form_all_explicit_managed_returns_owned(e, item, return_ty, depth+1) {
            return false
        }
    }
    return true
}

proc_decl_infers_owned_managed_result :: proc(e: ^Emitter, proc_decl: ^Proc_Decl) -> bool {
    if proc_decl == nil || len(proc_decl.body) == 0 {
        return false
    }
    return_ty := ""
    ok_return_ty := false
    if proc_decl.returns.kind == .Single {
        return_ty = proc_decl.returns.single_ty
        ok_return_ty = true
    } else if proc_decl.returns.kind == .Named && len(proc_decl.returns.named) == 1 {
        return_ty = proc_decl.returns.named[0].ty
        ok_return_ty = true
    }
    if !ok_return_ty || !type_text_has_managed_lifecycle(e, return_ty) {
        return false
    }
    if !form_produces_owned_managed_type(
        e,
        proc_decl.body[len(proc_decl.body)-1],
        return_ty,
    ) {
        return false
    }
    for form in proc_decl.body {
        if !form_all_explicit_managed_returns_owned(e, form, return_ty) {
            return false
        }
    }
    return true
}

owned_result_field_indices_equal :: proc(left, right: []int) -> bool {
    if len(left) != len(right) {
        return false
    }
    for value, index in left {
        if value != right[index] {
            return false
        }
    }
    return true
}

Aggregate_Result_Local_Field :: struct {
    name:        string,
    field_index: int,
}

aggregate_result_local_remove :: proc(
    name: string,
    known_names: ^[dynamic]string,
    fields: ^[dynamic]Aggregate_Result_Local_Field,
    uncertain_names: ^[dynamic]string,
) {
    for i := len(known_names[:]) - 1; i >= 0; i -= 1 {
        if known_names[i] == name {
            ordered_remove(known_names, i)
        }
    }
    for i := len(fields[:]) - 1; i >= 0; i -= 1 {
        if fields[i].name == name {
            ordered_remove(fields, i)
        }
    }
    for i := len(uncertain_names[:]) - 1; i >= 0; i -= 1 {
        if uncertain_names[i] == name {
            ordered_remove(uncertain_names, i)
        }
    }
}

aggregate_result_local_set :: proc(
    name: string,
    owned_fields: []int,
    known, uncertain: bool,
    known_names: ^[dynamic]string,
    fields: ^[dynamic]Aggregate_Result_Local_Field,
    uncertain_names: ^[dynamic]string,
) {
    if name == "" {
        return
    }
    aggregate_result_local_remove(
        name,
        known_names,
        fields,
        uncertain_names,
    )
    if known {
        append(known_names, name)
        for field_index in owned_fields {
            append(
                fields,
                Aggregate_Result_Local_Field{
                    name = name,
                    field_index = field_index,
                },
            )
        }
    } else if uncertain {
        append(uncertain_names, name)
    }
}

aggregate_result_local_has_owned_fields :: proc(
    name: string,
    fields: []Aggregate_Result_Local_Field,
) -> bool {
    for field in fields {
        if field.name == name {
            return true
        }
    }
    return false
}

aggregate_result_name_use_is_unsafe :: proc(
    e: ^Emitter,
    form: CST_Form,
    name: string,
) -> bool {
    return form_assigns_name(form, name) ||
           form_contains_delete_of_name(form, name) ||
           form_transfers_owned_name(e, form, name, false) ||
           composite_literal_transfers_owned_name(e, form, name) ||
           body_contains_result_capture([]CST_Form{form}, name)
}

aggregate_result_tail_context_use_is_unsafe :: proc(
    e: ^Emitter,
    form: CST_Form,
    name: string,
    depth: int = 0,
) -> bool {
    if depth > 16 || form.kind == .Symbol {
        return false
    }
    if form.kind == .Vector || form.kind == .Set {
        for item in form.items {
            if aggregate_result_tail_context_use_is_unsafe(
                e,
                item,
                name,
                depth+1,
            ) {
                return true
            }
        }
        return false
    }
    if form.kind != .List || len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return aggregate_result_name_use_is_unsafe(e, form, name)
    }
    switch form.items[0].text {
    case "return":
        if len(form.items) != 2 {
            return aggregate_result_name_use_is_unsafe(e, form, name)
        }
        return aggregate_result_tail_context_use_is_unsafe(
            e,
            form.items[1],
            name,
            depth+1,
        )
    case "do", "block":
        return aggregate_result_body_before_return_use_is_unsafe(
            e,
            form.items[1:],
            name,
            depth+1,
        )
    case "if":
        if len(form.items) != 4 ||
           aggregate_result_name_use_is_unsafe(e, form.items[1], name) {
            return true
        }
        return aggregate_result_tail_context_use_is_unsafe(
                   e,
                   form.items[2],
                   name,
                   depth+1,
               ) ||
               aggregate_result_tail_context_use_is_unsafe(
                   e,
                   form.items[3],
                   name,
                   depth+1,
               )
    case "let":
        if len(form.items) < 3 {
            return true
        }
        bindings, _, ok_bindings := parse_let_bindings(form.items[1])
        if !ok_bindings {
            return true
        }
        defer delete(bindings)
        for binding in bindings {
            if aggregate_result_name_use_is_unsafe(
                e,
                binding.value,
                name,
            ) {
                return true
            }
        }
        return aggregate_result_body_before_return_use_is_unsafe(
            e,
            form.items[2:],
            name,
            depth+1,
        )
    }
    return aggregate_result_name_use_is_unsafe(e, form, name)
}

aggregate_result_body_before_return_use_is_unsafe :: proc(
    e: ^Emitter,
    body: []CST_Form,
    name: string,
    depth: int = 0,
) -> bool {
    if depth > 16 || len(body) == 0 {
        return depth > 16
    }
    for form in body[:len(body)-1] {
        if aggregate_result_name_use_is_unsafe(e, form, name) {
            return true
        }
    }
    return aggregate_result_tail_context_use_is_unsafe(
        e,
        body[len(body)-1],
        name,
        depth+1,
    )
}

aggregate_result_local_use_is_unsafe :: proc(
    e: ^Emitter,
    form: CST_Form,
    name: string,
    return_struct: ^Struct_Decl,
    fields: []Aggregate_Result_Local_Field,
) -> bool {
    if aggregate_result_name_use_is_unsafe(e, form, name) {
        return true
    }
    for field in fields {
        if field.name != name || field.field_index < 0 ||
           field.field_index >= len(return_struct.fields) {
            continue
        }
        place_name := fmt.tprintf(
            "%s.%s",
            name,
            return_struct.fields[field.field_index].name,
        )
        unsafe := aggregate_result_name_use_is_unsafe(
            e,
            form,
            place_name,
        )
        delete(place_name)
        if unsafe {
            return true
        }
    }
    return false
}

aggregate_result_value_is_owned :: proc(
    e: ^Emitter,
    form: CST_Form,
    owned_names: []string,
) -> bool {
    if form.kind == .Symbol {
        name := map_name(form.text)
        defer delete(name)
        return string_slice_contains_name(owned_names, name)
    }
    return form_produces_owned_value(form, e)
}

form_contains_explicit_return :: proc(form: CST_Form, depth: int = 0) -> bool {
    if depth > 32 || form.kind != .List || len(form.items) == 0 {
        return false
    }
    if form.items[0].kind == .Symbol {
        switch form.items[0].text {
        case "return":
            return true
        case "fn", "quote", "quasiquote":
            return false
        }
    }
    for item in form.items[1:] {
        if form_contains_explicit_return(item, depth+1) {
            return true
        }
    }
    return false
}

aggregate_result_form_returns_name :: proc(
    form: CST_Form,
    name: string,
    depth: int = 0,
) -> bool {
    if depth > 16 {
        return false
    }
    if form.kind == .Symbol {
        mapped := map_name(form.text)
        defer delete(mapped)
        return mapped == name
    }
    if form.kind != .List || len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return false
    }
    switch form.items[0].text {
    case "return":
        return len(form.items) == 2 &&
               aggregate_result_form_returns_name(
                   form.items[1],
                   name,
                   depth+1,
               )
    case "do", "block":
        return len(form.items) > 1 &&
               aggregate_result_form_returns_name(
                   form.items[len(form.items)-1],
                   name,
                   depth+1,
               )
    case "if":
        return len(form.items) == 4 &&
               aggregate_result_form_returns_name(
                   form.items[2],
                   name,
                   depth+1,
               ) &&
               aggregate_result_form_returns_name(
                   form.items[3],
                   name,
                   depth+1,
               )
    case "let":
        if len(form.items) < 3 {
            return false
        }
        bindings, _, ok_bindings := parse_let_bindings(form.items[1])
        if !ok_bindings {
            return false
        }
        defer delete(bindings)
        for binding in bindings {
            if binding_declares_mapped_name(binding, name) {
                return false
            }
        }
        return aggregate_result_form_returns_name(
            form.items[len(form.items)-1],
            name,
            depth+1,
        )
    }
    return false
}

aggregate_result_body_returns_name :: proc(
    body: []CST_Form,
    name: string,
) -> bool {
    return len(body) > 0 &&
           aggregate_result_form_returns_name(body[len(body)-1], name)
}

aggregate_result_body_transfers_name :: proc(
    e: ^Emitter,
    body: []CST_Form,
    name: string,
) -> bool {
    if len(body) == 0 {
        return false
    }
    tail := body[len(body)-1]
    return form_transfers_owned_name(e, tail, name, true) ||
           composite_value_transfers_owned_name(e, tail, name)
}

proc_single_struct_return :: proc(
    e: ^Emitter,
    proc_decl: ^Proc_Decl,
) -> (^Struct_Decl, bool) {
    if proc_decl == nil {
        return nil, false
    }
    return_ty := ""
    if proc_decl.returns.kind == .Single {
        return_ty = proc_decl.returns.single_ty
    } else if proc_decl.returns.kind == .Named &&
              len(proc_decl.returns.named) == 1 {
        return_ty = proc_decl.returns.named[0].ty
    } else {
        return nil, false
    }
    struct_decl, ok_struct := find_struct_decl(e, strings.trim_space(return_ty))
    if !ok_struct || type_text_has_managed_lifecycle(e, struct_decl.name) {
        return nil, false
    }
    return struct_decl, true
}

aggregate_result_owned_fields :: proc(
    e: ^Emitter,
    form: CST_Form,
    return_struct: ^Struct_Decl,
    owned_names: []string,
    aggregate_names: []string,
    aggregate_fields: []Aggregate_Result_Local_Field,
    uncertain_aggregate_names: []string,
    uncertain: ^bool,
    depth: int = 0,
) -> (fields: [dynamic]int, known: bool) {
    if depth > 16 || return_struct == nil {
        return fields, false
    }
    if form.kind == .Symbol {
        name := map_name(form.text)
        defer delete(name)
        if string_slice_contains_name(uncertain_aggregate_names, name) {
            uncertain^ = true
            return fields, false
        }
        if !string_slice_contains_name(aggregate_names, name) {
            return fields, false
        }
        for field in aggregate_fields {
            if field.name == name {
                append(&fields, field.field_index)
            }
        }
        return fields, true
    }
    if form.kind != .List || len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return fields, false
    }
    head := form.items[0].text
    switch head {
    case "return":
        if len(form.items) != 2 {
            return fields, false
        }
        return aggregate_result_owned_fields(
            e,
            form.items[1],
            return_struct,
            owned_names,
            aggregate_names,
            aggregate_fields,
            uncertain_aggregate_names,
            uncertain,
            depth+1,
        )
    case "do", "block":
        if len(form.items) < 2 {
            return fields, false
        }
        for item in form.items[1:len(form.items)-1] {
            if form_contains_explicit_return(item) {
                uncertain^ = true
                return fields, false
            }
            for name in owned_names {
                if form_transfers_owned_name(e, item, name, false) {
                    return fields, false
                }
            }
            for name in aggregate_names {
                if aggregate_result_local_has_owned_fields(
                    name,
                    aggregate_fields,
                ) && aggregate_result_local_use_is_unsafe(
                    e,
                    item,
                    name,
                    return_struct,
                    aggregate_fields,
                ) {
                    uncertain^ = true
                    return fields, false
                }
            }
        }
        return aggregate_result_owned_fields(
            e,
            form.items[len(form.items)-1],
            return_struct,
            owned_names,
            aggregate_names,
            aggregate_fields,
            uncertain_aggregate_names,
            uncertain,
            depth+1,
        )
    case "if":
        if len(form.items) != 4 {
            return fields, false
        }
        for name in aggregate_names {
            if aggregate_result_local_has_owned_fields(
                name,
                aggregate_fields,
            ) && aggregate_result_local_use_is_unsafe(
                e,
                form.items[1],
                name,
                return_struct,
                aggregate_fields,
            ) {
                uncertain^ = true
                return fields, false
            }
        }
        then_fields, then_known := aggregate_result_owned_fields(
            e,
            form.items[2],
            return_struct,
            owned_names,
            aggregate_names,
            aggregate_fields,
            uncertain_aggregate_names,
            uncertain,
            depth+1,
        )
        defer delete(then_fields)
        if !then_known {
            return fields, false
        }
        else_fields, else_known := aggregate_result_owned_fields(
            e,
            form.items[3],
            return_struct,
            owned_names,
            aggregate_names,
            aggregate_fields,
            uncertain_aggregate_names,
            uncertain,
            depth+1,
        )
        defer delete(else_fields)
        if !else_known ||
           !owned_result_field_indices_equal(then_fields[:], else_fields[:]) {
            if else_known {
                uncertain^ = true
            }
            return fields, false
        }
        append(&fields, ..then_fields[:])
        return fields, true
    case "let":
        if len(form.items) < 3 {
            return fields, false
        }
        bindings, _, ok_bindings := parse_let_bindings(form.items[1])
        if !ok_bindings {
            return fields, false
        }
        defer delete(bindings)
        scoped_names: [dynamic]string
        defer delete(scoped_names)
        append(&scoped_names, ..owned_names)
        scoped_aggregate_names: [dynamic]string
        defer delete(scoped_aggregate_names)
        append(&scoped_aggregate_names, ..aggregate_names)
        scoped_aggregate_fields: [dynamic]Aggregate_Result_Local_Field
        defer delete(scoped_aggregate_fields)
        append(&scoped_aggregate_fields, ..aggregate_fields)
        scoped_uncertain_aggregate_names: [dynamic]string
        defer delete(scoped_uncertain_aggregate_names)
        append(
            &scoped_uncertain_aggregate_names,
            ..uncertain_aggregate_names,
        )
        for binding in bindings {
            for name in scoped_aggregate_names {
                if aggregate_result_local_has_owned_fields(
                    name,
                    scoped_aggregate_fields[:],
                ) && aggregate_result_local_use_is_unsafe(
                    e,
                    binding.value,
                    name,
                    return_struct,
                    scoped_aggregate_fields[:],
                ) {
                    uncertain^ = true
                    return fields, false
                }
            }
            if binding.is_destructure || binding.is_result_binding {
                for name, result_index in binding.pattern {
                    if name == "" {
                        continue
                    }
                    aggregate_result_local_remove(
                        name,
                        &scoped_aggregate_names,
                        &scoped_aggregate_fields,
                        &scoped_uncertain_aggregate_names,
                    )
                    lifecycle, lifecycle_known := infer_result_lifecycle(
                        e,
                        binding.value,
                        result_index,
                        len(binding.pattern),
                    )
                    if lifecycle_known && result_lifecycle_is_owned(lifecycle) {
                        append(&scoped_names, name)
                    }
                    result_lifecycle_delete(&lifecycle)
                }
                continue
            }
            binding_fields, binding_known := aggregate_result_owned_fields(
                e,
                binding.value,
                return_struct,
                scoped_names[:],
                scoped_aggregate_names[:],
                scoped_aggregate_fields[:],
                scoped_uncertain_aggregate_names[:],
                uncertain,
                depth+1,
            )
            binding_uncertain := uncertain^ && !binding_known
            if binding.name != "" {
                aggregate_result_local_set(
                    binding.name,
                    binding_fields[:],
                    binding_known,
                    binding_uncertain,
                    &scoped_aggregate_names,
                    &scoped_aggregate_fields,
                    &scoped_uncertain_aggregate_names,
                )
            }
            delete(binding_fields)
            if binding.name != "" &&
               aggregate_result_value_is_owned(
                   e,
                   binding.value,
                   scoped_names[:],
               ) {
                append(&scoped_names, binding.name)
            }
        }
        body := form.items[2:]
        for item in body[:len(body)-1] {
            if form_contains_explicit_return(item) {
                uncertain^ = true
                return fields, false
            }
            for name in scoped_names {
                if form_transfers_owned_name(e, item, name, false) {
                    return fields, false
                }
            }
            for name in scoped_aggregate_names {
                if aggregate_result_local_has_owned_fields(
                    name,
                    scoped_aggregate_fields[:],
                ) && aggregate_result_local_use_is_unsafe(
                    e,
                    item,
                    name,
                    return_struct,
                    scoped_aggregate_fields[:],
                ) {
                    uncertain^ = true
                    return fields, false
                }
            }
        }
        return aggregate_result_owned_fields(
            e,
            body[len(body)-1],
            return_struct,
            scoped_names[:],
            scoped_aggregate_names[:],
            scoped_aggregate_fields[:],
            scoped_uncertain_aggregate_names[:],
            uncertain,
            depth+1,
        )
    }

    mapped_head := map_name(head)
    defer delete(mapped_head)
    if mapped_head == return_struct.name {
        for item, item_index in form.items[1:] {
            if !aggregate_result_value_is_owned(e, item, owned_names) {
                continue
            }
            field, ok_field := ownership_ir_struct_field_for_call_arg(
                e,
                form,
                item_index+1,
            )
            if !ok_field || !type_supports_automatic_native_delete(field.ty) {
                continue
            }
            for candidate, field_index in return_struct.fields {
                if candidate.name == field.name {
                    append(&fields, field_index)
                    break
                }
            }
        }
        return fields, true
    }
    if _, called_proc, ok_proc := resolve_proc_call_decl(e, head);
       ok_proc && called_proc != nil {
        called_struct, ok_called_struct := proc_single_struct_return(e, called_proc)
        if ok_called_struct &&
           called_struct.name == return_struct.name &&
           len(called_proc.owned_result_fields) > 0 {
            append(&fields, ..called_proc.owned_result_fields[:])
            return fields, true
        }
        if ok_called_struct &&
           called_struct.name == return_struct.name &&
           called_proc.owned_result_fields_uncertain {
            uncertain^ = true
        }
    }
    return fields, false
}

proc_decl_infer_owned_result_fields :: proc(
    e: ^Emitter,
    proc_decl: ^Proc_Decl,
) -> (fields: [dynamic]int, known, uncertain: bool) {
    return_struct, ok_struct := proc_single_struct_return(e, proc_decl)
    if !ok_struct || len(proc_decl.body) == 0 {
        return fields, false, uncertain
    }
    owned_names: [dynamic]string
    defer delete(owned_names)
    for param in proc_decl.params {
        if param.ownership == .Owned {
            append(&owned_names, param.name)
        }
    }
    for item in proc_decl.body[:len(proc_decl.body)-1] {
        if form_contains_explicit_return(item) {
            uncertain = true
            return fields, false, uncertain
        }
        for name in owned_names {
            if form_transfers_owned_name(e, item, name, false) {
                return fields, false, uncertain
            }
        }
    }
    inferred_fields, inferred := aggregate_result_owned_fields(
        e,
        proc_decl.body[len(proc_decl.body)-1],
        return_struct,
        owned_names[:],
        nil,
        nil,
        nil,
        &uncertain,
    )
    return inferred_fields, inferred, uncertain
}

infer_proc_lifetime_facts :: proc(e: ^Emitter) {
    // Lifetime contracts are compiler facts derived from ordinary procedure
    // bodies. Iterate because one procedure may forward an owned or borrowed
    // result produced by another procedure in the same source package.
    for _ in 0..<8 {
        changed := false
        for &decl in e.decls {
            if decl.kind != .Proc {
                continue
            }
            proc_decl := &decl.proc_decl
            borrows_result := proc_decl_infers_borrowed_tail_call(e, proc_decl, 0)
            owns_result := !borrows_result &&
                           (proc_decl_infers_owned_result(e, proc_decl) ||
                            proc_decl_infers_owned_managed_result(e, proc_decl) ||
                            (len(proc_decl.body) > 0 &&
                             form_produces_owned_value(
                                 proc_decl.body[len(proc_decl.body)-1],
                                 e,
                             )) ||
                            (len(proc_decl.body) > 0 &&
                             form_infers_known_foreign_lifetime(
                                 proc_decl.body[len(proc_decl.body)-1],
                                 .Owned,
                                 0,
                                 e,
                             )))
            if owns_result && !proc_decl.owns_result {
                proc_decl.owns_result = true
                changed = true
            }
            if borrows_result && !proc_decl.borrows_result {
                proc_decl.borrows_result = true
                changed = true
            }
            if len(proc_decl.owned_result_fields) == 0 {
                owned_fields, known_owned_fields, uncertain_owned_fields :=
                    proc_decl_infer_owned_result_fields(e, proc_decl)
                if known_owned_fields && len(owned_fields) > 0 {
                    append(
                        &proc_decl.owned_result_fields,
                        ..owned_fields[:],
                    )
                    changed = true
                }
                if uncertain_owned_fields &&
                   !proc_decl.owned_result_fields_uncertain {
                    proc_decl.owned_result_fields_uncertain = true
                    changed = true
                }
                delete(owned_fields)
            }
            for &param in proc_decl.params {
                if param.ownership == .Owned {
                    continue
                }
                explicit_consumption :=
                    body_deletes_or_returns_name(e, proc_decl.body[:], param.name, false)
                transferred_result :=
                    !type_text_has_managed_lifecycle(e, param.ty) &&
                    proc_decl.owns_result &&
                    body_deletes_or_returns_name(e, proc_decl.body[:], param.name, true)
                if explicit_consumption || transferred_result {
                    param.ownership = .Owned
                    changed = true
                }
            }
        }
        if !changed {
            break
        }
    }
}

infer_decoded_struct_lifetime :: proc(e: ^Emitter, type_name: string, depth: int = 0) {
    if depth > 16 {
        return
    }
    if elem_ty, ok_elem := dynamic_array_element_type(strings.trim_space(type_name)); ok_elem {
        infer_decoded_struct_lifetime(e, elem_ty, depth+1)
        return
    }
    struct_decl, ok_struct := find_struct_decl(e, strings.trim_space(type_name))
    if !ok_struct {
        return
    }
    for &field in struct_decl.fields {
        if field.ty == "string" {
            field.owns_string = true
            continue
        }
        if type_text_is_dynamic_array(field.ty) {
            field.owns_dynamic_array = true
            if elem_ty, ok_elem := dynamic_array_element_type(field.ty); ok_elem {
                infer_decoded_struct_lifetime(e, elem_ty, depth+1)
            }
            continue
        }
        infer_decoded_struct_lifetime(e, field.ty, depth+1)
    }
}

infer_decoded_struct_lifetimes_form :: proc(e: ^Emitter, form: CST_Form) {
    if form.kind == .List &&
       len(form.items) >= 2 &&
       form.items[0].kind == .Symbol {
        head_name := map_name(form.items[0].text)
        if head_name == "decode_data" ||
           head_name == "validate_data" ||
           head_name == "data_decode" ||
           head_name == "data_validate" ||
           head_name == "data.decode" ||
           head_name == "data.validate" {
            if target_ty, _, ok_target := parse_type_text(form.items[1]); ok_target {
                infer_decoded_struct_lifetime(e, target_ty)
            }
        }
        delete(head_name)
    }
    for item in form.items {
        infer_decoded_struct_lifetimes_form(e, item)
    }
}

infer_decoded_struct_lifetimes :: proc(e: ^Emitter, extra_form: ^CST_Form = nil) {
    for decl in e.decls {
        #partial switch decl.kind {
        case .Proc:
            for form in decl.proc_decl.body {
                infer_decoded_struct_lifetimes_form(e, form)
            }
        case .Source:
            for form in decl.source_decl.body {
                infer_decoded_struct_lifetimes_form(e, form)
            }
        case .Const:
            infer_decoded_struct_lifetimes_form(e, decl.const_decl.value)
        case .Var:
            if decl.var_decl.has_value {
                infer_decoded_struct_lifetimes_form(e, decl.var_decl.value)
            }
        case:
        }
    }
    if extra_form != nil {
        infer_decoded_struct_lifetimes_form(e, extra_form^)
    }
}
