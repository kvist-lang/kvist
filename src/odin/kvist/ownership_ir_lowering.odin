package kvist

import "base:runtime"
import "core:fmt"
import "core:strings"

// Lowering keeps non-local exits explicit until the construct that owns them
// consumes them. A loop consumes break/continue; each lexical resource scope
// wraps every remaining exit in its own cleanup boundary.
Ownership_IR_Exit :: struct {
    kind:        Ownership_IR_Exit_Kind,
    source:      Ownership_IR_Exit_Source,
    block:       int,
    span:        Span,
    source_form: CST_Form,
}

Ownership_IR_Flow :: struct {
    exits: [dynamic]Ownership_IR_Exit,
}

Ownership_IR_Shadow_Place :: struct {
    place:                    int,
    name:                     string,
    ty:                       string,
    aggregate_root:           string,
    aggregate_cleanup_unsupported: bool,
    aggregate_return_transfers_owner: bool,
    cleanup_head:             string,
    activation:               Ownership_Activation,
    activation_index:         int,
    scope_exits:              [dynamic]Ownership_IR_Exit,
    legacy_cleanup:           Ownership_IR_Cleanup_Need,
    cleanup_skip_reason:      Ownership_IR_Cleanup_Skip_Reason,
    cleanup_scheduled:        bool,
    diagnose_use_after_transfer: bool,
    diagnose_unreleased:      bool,
    diagnose_discarded_result: bool,
    discard_supports_scoped_cleanup: bool,
    transient:                bool,
    borrowed_provenance:      bool,
    automatic_cleanup:        Ownership_IR_Automatic_Cleanup,
    direct_imported_contract: bool,
    span:                     Span,
}

Ownership_IR_Shadow_Proc :: struct {
    name:                  string,
    return_count:          int,
    graph:                 Ownership_IR_Proc,
    places:                [dynamic]Ownership_IR_Shadow_Place,
    diagnostic_candidates: [dynamic]Ownership_IR_Diagnostic_Fact,
}

Ownership_IR_Shadow_Stats :: struct {
    procedures:  int,
    places:      int,
    actions:     int,
    always:      int,
    conditional: int,
    matches:     int,
    mismatches:  int,
    invalid:     int,
}

Ownership_IR_Name_Binding :: struct {
    name:  string,
    place: int,
}

Ownership_IR_Active_Place :: struct {
    place:      int,
    owner_flag: string,
}

Ownership_IR_Lowering :: struct {
    emitter: ^Emitter,
    result:  Ownership_IR_Shadow_Proc,
    names:   [dynamic]Ownership_IR_Name_Binding,
    borrows: [dynamic]Ownership_IR_Name_Binding,
}

ownership_ir_shadow_proc_delete :: proc(result: ^Ownership_IR_Shadow_Proc) {
    delete(result.name)
    ownership_ir_proc_delete(&result.graph)
    for &place in result.places {
        delete(place.name)
        delete(place.ty)
        delete(place.aggregate_root)
        delete(place.cleanup_head)
        delete(place.scope_exits)
    }
    delete(result.places)
    for &diagnostic in result.diagnostic_candidates {
        delete(diagnostic.subject)
    }
    delete(result.diagnostic_candidates)
    result^ = {}
}

ownership_ir_flow_delete :: proc(flow: ^Ownership_IR_Flow) {
    delete(flow.exits)
    flow^ = {}
}

ownership_ir_flow_single :: proc(
    block: int,
    kind := Ownership_IR_Exit_Kind.Fallthrough,
    span := Span{},
    source_form := CST_Form{},
    source := Ownership_IR_Exit_Source.Synthetic,
) -> Ownership_IR_Flow {
    result := Ownership_IR_Flow{}
    append(&result.exits, Ownership_IR_Exit{
        kind = kind,
        source = source,
        block = block,
        span = span,
        source_form = source_form,
    })
    return result
}

ownership_ir_tail_flow :: proc(
    block: int,
    form: CST_Form,
    can_transfer: bool,
) -> Ownership_IR_Flow {
    if !can_transfer {
        return ownership_ir_flow_single(block)
    }
    return ownership_ir_flow_single(
        block,
        .Return,
        form.span,
        form,
        .Tail,
    )
}

ownership_ir_flow_append :: proc(
    flow: ^Ownership_IR_Flow,
    exit: Ownership_IR_Exit,
) {
    append(&flow.exits, exit)
}

ownership_ir_lowering_delete :: proc(lowering: ^Ownership_IR_Lowering) {
    for &binding in lowering.names {
        delete(binding.name)
    }
    delete(lowering.names)
    for &binding in lowering.borrows {
        delete(binding.name)
    }
    delete(lowering.borrows)
}

ownership_ir_lookup_name :: proc(
    lowering: ^Ownership_IR_Lowering,
    raw_name: string,
) -> (int, bool) {
    name := map_name(raw_name)
    defer delete(name)
    for index := len(lowering.names) - 1; index >= 0; index -= 1 {
        if lowering.names[index].name == name {
            return lowering.names[index].place, true
        }
    }
    return -1, false
}

ownership_ir_lookup_borrow_name :: proc(
    lowering: ^Ownership_IR_Lowering,
    raw_name: string,
) -> (int, bool) {
    name := map_name(raw_name)
    defer delete(name)
    for index := len(lowering.borrows)-1; index >= 0; index -= 1 {
        if lowering.borrows[index].name == name {
            return lowering.borrows[index].place, true
        }
    }
    return -1, false
}

ownership_ir_lower_borrow_use :: proc(
    lowering: ^Ownership_IR_Lowering,
    raw_name: string,
    block: int,
    span: Span,
) {
    if borrower, found := ownership_ir_lookup_borrow_name(
        lowering,
        raw_name,
    ); found {
        _ = ownership_ir_add_event(
            &lowering.result.graph,
            block,
            {kind = .Borrow_Use, place = borrower, span = span},
        )
    }
}

ownership_ir_bind_name :: proc(
    lowering: ^Ownership_IR_Lowering,
    name: string,
    place: int,
) {
    if name == "" {
        return
    }
    append(&lowering.names, Ownership_IR_Name_Binding{
        name = strings.clone(name),
        place = place,
    })
}

ownership_ir_bind_borrow_name :: proc(
    lowering: ^Ownership_IR_Lowering,
    name: string,
    place: int,
) {
    if name == "" {
        return
    }
    append(&lowering.borrows, Ownership_IR_Name_Binding{
        name = strings.clone(name),
        place = place,
    })
}

ownership_ir_cleanup_head_for_lifecycle :: proc(
    lifecycle: Result_Lifecycle,
) -> string {
    #partial switch lifecycle.kind {
    case .Owned_Delete:
        return strings.clone("delete")
    case .Owned_Custom:
        return strings.clone(lifecycle.cleanup_head)
    case .Unknown, .Borrowed:
        return ""
    }
    return ""
}

ownership_ir_schedule_binding_cleanup :: proc(
    lowering: ^Ownership_IR_Lowering,
    binding: Binding,
    block: int,
) {
    if !binding.deferred_delete &&
       !binding.err_deferred_delete &&
       !binding.defer_with_cleanup {
        return
    }
    cleanup_name, ok_cleanup_name := binding_delete_target_name(binding)
    if !ok_cleanup_name {
        return
    }
    place, found := ownership_ir_lookup_name(lowering, cleanup_name)
    if !found {
        return
    }
    _ = ownership_ir_add_event(
        &lowering.result.graph,
        block,
        {
            kind = .Schedule_Destroy,
            place = place,
            conditional = binding.err_deferred_delete,
            span = binding.target_span,
        },
    )
}

ownership_ir_legacy_cleanup_need :: proc(
    e: ^Emitter,
    binding: Binding,
    bindings: []Binding,
    binding_index: int,
    body: []CST_Form,
    result_index: int,
) -> Ownership_IR_Cleanup_Need {
    lifecycle, known := infer_result_lifecycle(
        e,
        binding.value,
        result_index,
        len(binding.pattern),
    )
    if !known {
        return .None
    }
    defer result_lifecycle_delete(&lifecycle)
    if !result_lifecycle_is_owned(lifecycle) ||
       result_index < 0 ||
       result_index >= len(binding.pattern) ||
       !destructured_result_cleanup_is_safe(
           e,
           bindings,
           binding_index,
           body,
           binding.pattern[result_index],
       ) ||
       !result_lifecycle_condition_is_stable(
           lifecycle,
           binding.pattern[:],
           body,
       ) {
        return .None
    }
    return .Always if lifecycle.condition == .Always else .Conditional
}

ownership_ir_add_shadow_place :: proc(
    lowering: ^Ownership_IR_Lowering,
    name, cleanup_head: string,
    activation: Ownership_Activation,
    activation_index: int,
    legacy_cleanup: Ownership_IR_Cleanup_Need,
    direct_imported_contract: bool,
    span: Span,
    ty := "",
    aggregate_root := "",
    aggregate_cleanup_unsupported := false,
    cleanup_skip_reason := Ownership_IR_Cleanup_Skip_Reason.None,
    cleanup_scheduled := false,
    diagnose_use_after_transfer := false,
    diagnose_unreleased := false,
    automatic_cleanup := Ownership_IR_Automatic_Cleanup.None,
) -> int {
    place := lowering.result.graph.place_count
    lowering.result.graph.place_count += 1
    append(&lowering.result.places, Ownership_IR_Shadow_Place{
        place = place,
        name = strings.clone(name),
        ty = strings.clone(ty),
        aggregate_root = strings.clone(aggregate_root),
        aggregate_cleanup_unsupported = aggregate_cleanup_unsupported,
        cleanup_head = strings.clone(cleanup_head),
        activation = activation,
        activation_index = activation_index,
        legacy_cleanup = legacy_cleanup,
        cleanup_skip_reason = cleanup_skip_reason,
        cleanup_scheduled = cleanup_scheduled,
        diagnose_use_after_transfer = diagnose_use_after_transfer,
        diagnose_unreleased = diagnose_unreleased,
        automatic_cleanup = automatic_cleanup,
        direct_imported_contract = direct_imported_contract,
        span = span,
    })
    ownership_ir_bind_name(lowering, name, place)
    return place
}

ownership_ir_binding_automatic_cleanup :: proc(
    e: ^Emitter,
    binding: Binding,
) -> Ownership_IR_Automatic_Cleanup {
    ty, ok_ty := obvious_binding_type(e, binding)
    if !ok_ty ||
       !ownership_type_has_destructor(e, ty) ||
       binding.name == "" ||
       binding.is_destructure ||
       binding.is_result_binding {
        return .None
    }
    if form_produces_owned_managed_type(e, binding.value, ty) ||
       type_text_has_data_lifecycle(e, ty) {
        return .Managed
    }
    if binding_supports_automatic_native_cleanup(e, binding) {
        return .Native
    }
    return .None
}

ownership_ir_add_transient_place :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
    automatic_cleanup: Ownership_IR_Automatic_Cleanup,
    diagnose_discarded_result: bool,
) -> int {
    subject := owned_warning_subject(form)
    place := lowering.result.graph.place_count
    lowering.result.graph.place_count += 1
    append(&lowering.result.places, Ownership_IR_Shadow_Place{
        place = place,
        name = strings.clone(subject),
        diagnose_discarded_result = diagnose_discarded_result,
        discard_supports_scoped_cleanup =
            discarded_result_has_automatic_cleanup(
                lowering.emitter,
                form,
            ),
        transient = true,
        automatic_cleanup = automatic_cleanup,
        span = form.span,
    })
    return place
}

ownership_ir_add_borrow_place :: proc(
    lowering: ^Ownership_IR_Lowering,
    name: string,
    span: Span,
    transient := false,
    bind_name := true,
) -> int {
    place := lowering.result.graph.place_count
    lowering.result.graph.place_count += 1
    append(&lowering.result.places, Ownership_IR_Shadow_Place{
        place = place,
        name = strings.clone(name),
        transient = transient,
        borrowed_provenance = true,
        span = span,
    })
    if bind_name {
        ownership_ir_bind_borrow_name(lowering, name, place)
    }
    return place
}

ownership_ir_lower_borrow_assignment :: proc(
    lowering: ^Ownership_IR_Lowering,
    target: int,
    value: CST_Form,
    block: int,
) {
    if target < 0 {
        return
    }
    if value.kind == .Symbol {
        if source, found := ownership_ir_lookup_borrow_name(
            lowering,
            value.text,
        ); found {
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {
                    kind = .Borrow_Copy,
                    place = target,
                    target = source,
                    span = value.span,
                },
            )
            return
        }
    }
    if owner_name, found := form_direct_borrow_owner_name(
        value,
        lowering.emitter,
    ); found {
        defer delete(owner_name)
        if owner, has_owner := ownership_ir_lookup_name(
            lowering,
            owner_name,
        ); has_owner {
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {
                    kind = .Borrow_Assign,
                    place = target,
                    target = owner,
                    span = value.span,
                },
            )
            return
        }
        if source, has_source := ownership_ir_lookup_borrow_name(
            lowering,
            owner_name,
        ); has_source {
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {
                    kind = .Borrow_Copy,
                    place = target,
                    target = source,
                    span = value.span,
                },
            )
            return
        }
    }
    if form_is_borrowed_view_result(value, lowering.emitter) {
        // A borrowed result can depend on an untracked owner such as a
        // procedure parameter. Keep that borrowed-ness in the provenance
        // lattice without treating the external owner as a scoped local.
        _ = ownership_ir_add_event(
            &lowering.result.graph,
            block,
            {
                kind = .Borrow_Assign,
                place = target,
                target = target,
                span = value.span,
            },
        )
        return
    }
    _ = ownership_ir_add_event(
        &lowering.result.graph,
        block,
        {
            kind = .Borrow_Clear,
            place = target,
            span = value.span,
        },
    )
}

ownership_ir_lower_borrow_delete :: proc(
    lowering: ^Ownership_IR_Lowering,
    value: CST_Form,
    block: int,
) {
    if form_is_borrowed_view_result(value, lowering.emitter) {
        subject := owned_warning_subject(value)
        place := ownership_ir_add_borrow_place(
            lowering,
            subject,
            value.span,
            transient = true,
            bind_name = false,
        )
        ownership_ir_lower_borrow_assignment(
            lowering,
            place,
            value,
            block,
        )
        _ = ownership_ir_add_event(
            &lowering.result.graph,
            block,
            {kind = .Borrow_Delete, place = place, span = value.span},
        )
        return
    }
    if value.kind != .Symbol {
        return
    }
    if place, found := ownership_ir_lookup_borrow_name(
        lowering,
        value.text,
    ); found {
        _ = ownership_ir_add_event(
            &lowering.result.graph,
            block,
            {kind = .Borrow_Delete, place = place, span = value.span},
        )
    }
}

ownership_ir_lower_discarded_result :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
    block: int,
) {
    diagnose :=
        (form_requires_explicit_owned_cleanup(form, lowering.emitter) ||
         form_has_owned_result_lifecycle(lowering.emitter, form)) &&
        !form_supports_automatic_native_delete(form, lowering.emitter)
    handled := form_requires_owned_discard_cleanup(lowering.emitter, form) &&
               !diagnose
    if !diagnose && !handled {
        return
    }
    automatic_cleanup := Ownership_IR_Automatic_Cleanup.None
    if handled {
        automatic_cleanup = .Native
        if !form_supports_automatic_native_delete(form, lowering.emitter) {
            automatic_cleanup = .Managed
        }
    }
    place := ownership_ir_add_transient_place(
        lowering,
        form,
        automatic_cleanup,
        diagnose,
    )
    _ = ownership_ir_add_event(
        &lowering.result.graph,
        block,
        {kind = .Acquire, place = place, span = form.span},
    )
    _ = ownership_ir_add_event(
        &lowering.result.graph,
        block,
        {
            kind = .Discard if diagnose else .Destroy,
            place = place,
            span = form.span,
        },
    )
}

ownership_ir_lower_binding :: proc(
    lowering: ^Ownership_IR_Lowering,
    binding: Binding,
    bindings: []Binding,
    binding_index: int,
    body: []CST_Form,
    block: int,
    scope_places: ^[dynamic]int,
) {
    // Binding values are evaluated before the new name enters scope. Lower
    // their ownership events against the already-active places.
    if binding.value.kind == .List && len(binding.value.items) >= 3 &&
       binding.value.items[0].kind == .Symbol &&
       binding.value.items[0].text == "if" {
        ownership_ir_lower_value_uses(
            lowering,
            binding.value,
            block,
        )
    } else {
        ownership_ir_lower_call(
            lowering,
            binding.value,
            block,
            binding,
            scope_places,
            body,
        )
    }
    if proc_call_owned_result_fields_are_uncertain(
        lowering.emitter,
        binding.value,
    ) {
        head, ok_head := form_head_symbol_text(binding.value)
        if ok_head {
            append(
                &lowering.result.diagnostic_candidates,
                Ownership_IR_Diagnostic_Fact{
                    kind = .Aggregate_Result_Fields_Uncertain,
                    subject = strings.clone(head),
                    span = binding.value.span,
                },
            )
        }
    }
    if !binding.is_destructure && !binding.is_result_binding &&
       binding.name != "" {
        returned_fields := proc_call_owned_result_fields(
            lowering.emitter,
            binding.value,
        )
        defer delete(returned_fields)
        for field in returned_fields {
            if place, added := ownership_ir_add_struct_field_place(
                lowering,
                binding,
                field,
                scope_places,
                body,
            ); added {
                _ = ownership_ir_add_event(
                    &lowering.result.graph,
                    block,
                    {
                        kind = .Acquire,
                        place = place,
                        span = binding.value.span,
                    },
                )
            }
        }
    }
    if (binding.is_destructure || binding.is_result_binding) &&
       binding.value.kind == .List &&
       len(binding.value.items) > 0 &&
       binding.value.items[0].kind == .Symbol {
        result_count, known_count := result_lifecycle_call_result_count(
            lowering.emitter,
            binding.value,
        )
        direct_count, direct_imported_contract := ownership_imported_call_result_count(
            lowering.emitter,
            binding.value.items[0].text,
        )
        direct_imported_contract = direct_imported_contract && direct_count == result_count
        if known_count && result_count == len(binding.pattern) {
            acquired_place := false
            for name, result_index in binding.pattern {
                if name == "" {
                    continue
                }
                lifecycle, known_lifecycle := infer_result_lifecycle(
                    lowering.emitter,
                    binding.value,
                    result_index,
                    result_count,
                )
                if !known_lifecycle {
                    continue
                }
                if !result_lifecycle_is_owned(lifecycle) {
                    result_lifecycle_delete(&lifecycle)
                    continue
                }
                conditional_acquire := lifecycle.condition != .Always
                activation := lifecycle.condition
                activation_index := lifecycle.condition_index
                cleanup_head := ownership_ir_cleanup_head_for_lifecycle(
                    lifecycle,
                )
                result_lifecycle_delete(&lifecycle)
                legacy_cleanup := ownership_ir_legacy_cleanup_need(
                    lowering.emitter,
                    binding,
                    bindings,
                    binding_index,
                    body,
                    result_index,
                )
                cleanup_skip_reason := Ownership_IR_Cleanup_Skip_Reason.None
                if !destructured_result_cleanup_is_safe(
                    lowering.emitter,
                    bindings,
                    binding_index,
                    body,
                    name,
                ) {
                    cleanup_skip_reason = automatic_result_cleanup_skip_reason(
                        lowering.emitter,
                        bindings,
                        binding_index,
                        body,
                        name,
                    )
                }
                place := ownership_ir_add_shadow_place(
                    lowering,
                    name,
                    cleanup_head,
                    activation,
                    activation_index,
                    legacy_cleanup,
                    direct_imported_contract,
                    binding.target_span,
                    cleanup_skip_reason = cleanup_skip_reason,
                    diagnose_use_after_transfer = true,
                )
                delete(cleanup_head)
                append(scope_places, place)
                acquired_place = true
                _ = ownership_ir_add_event(
                    &lowering.result.graph,
                    block,
                    {
                        kind = .Acquire,
                        place = place,
                        conditional = conditional_acquire,
                        span = binding.value.span,
                    },
                )
            }
            if acquired_place {
                ownership_ir_schedule_binding_cleanup(lowering, binding, block)
            }
            return
        }
    }

    if !binding.is_destructure &&
       binding.name != "" &&
       binding.value.kind == .Symbol {
        ownership_ir_bind_aggregate_alias(
            lowering,
            binding.name,
            binding.value.text,
            bindings,
            binding_index,
            body,
        )
        if place, found := ownership_ir_lookup_name(lowering, binding.value.text); found {
            ownership_ir_bind_name(lowering, binding.name, place)
        }
    }
    if !binding.is_destructure && !binding.is_result_binding &&
       binding.name != "" {
        automatic_cleanup := ownership_ir_binding_automatic_cleanup(
            lowering.emitter,
            binding,
        )
        if binding_value_produces_owned_value(binding, lowering.emitter) ||
           automatic_cleanup != .None || binding.deferred_delete ||
           binding.err_deferred_delete || binding.defer_with_cleanup {
            place := ownership_ir_add_shadow_place(
                lowering,
                binding.name,
                "",
                .Always,
                -1,
                .None,
                false,
                binding.target_span,
                cleanup_scheduled = binding.deferred_delete ||
                                    binding.err_deferred_delete ||
                                    binding.defer_with_cleanup,
                diagnose_use_after_transfer = true,
                diagnose_unreleased = true,
                automatic_cleanup = automatic_cleanup,
            )
            append(scope_places, place)
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {
                    kind = .Acquire,
                    place = place,
                    span = binding.value.span,
                },
            )
            ownership_ir_schedule_binding_cleanup(lowering, binding, block)
        }
        borrow_place := ownership_ir_add_borrow_place(
            lowering,
            binding.name,
            binding.target_span,
        )
        ownership_ir_lower_borrow_assignment(
            lowering,
            borrow_place,
            binding.value,
            block,
        )
        if binding.deferred_delete || binding.defer_with_cleanup {
            ownership_ir_lower_borrow_delete(
                lowering,
                binding.value,
                block,
            )
        }
    }
}

ownership_ir_struct_field_for_call_arg :: proc(
    e: ^Emitter,
    form: CST_Form,
    item_index: int,
) -> (^Struct_Field, bool) {
    if form.kind != .List || len(form.items) == 0 ||
       form.items[0].kind != .Symbol || item_index < 1 ||
       item_index >= len(form.items) {
        return nil, false
    }
    type_name := map_name(form.items[0].text)
    defer delete(type_name)
    struct_decl, ok_struct := find_struct_decl(e, type_name)
    if !ok_struct {
        return nil, false
    }
    args := form.items[1:]
    arg_index := item_index-1
    if struct_args_use_named_fields(args) {
        if arg_index%2 != 1 {
            return nil, false
        }
        field_name, ok_name := brace_key_name(args[arg_index-1])
        if !ok_name {
            return nil, false
        }
        return find_struct_field(struct_decl, field_name)
    }
    if arg_index >= len(struct_decl.fields) {
        return nil, false
    }
    return &struct_decl.fields[arg_index], true
}

proc_call_owned_result_fields :: proc(
    e: ^Emitter,
    form: CST_Form,
) -> (fields: [dynamic]Struct_Field) {
    if e == nil || form.kind != .List || len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return fields
    }
    _, proc_decl, ok_proc := resolve_proc_call_decl(e, form.items[0].text)
    if !ok_proc || proc_decl == nil {
        return fields
    }
    contract := procedure_result_ownership_contract(proc_decl, e)
    defer procedure_ownership_contract_delete(&contract)
    if len(contract.owned_result_fields) == 0 {
        return fields
    }
    return_struct, ok_struct := proc_single_struct_return(e, proc_decl)
    if !ok_struct {
        return fields
    }
    for field_index in contract.owned_result_fields {
        if field_index >= 0 && field_index < len(return_struct.fields) {
            append(&fields, return_struct.fields[field_index])
        }
    }
    return fields
}

proc_call_owned_result_fields_are_uncertain :: proc(
    e: ^Emitter,
    form: CST_Form,
) -> bool {
    if e == nil || form.kind != .List || len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return false
    }
    _, proc_decl, ok_proc := resolve_proc_call_decl(e, form.items[0].text)
    if !ok_proc || proc_decl == nil {
        return false
    }
    contract := procedure_result_ownership_contract(proc_decl, e)
    defer procedure_ownership_contract_delete(&contract)
    return contract.result_fields_uncertain
}

ownership_ir_add_struct_field_place :: proc(
    lowering: ^Ownership_IR_Lowering,
    binding: Binding,
    field: Struct_Field,
    scope_places: ^[dynamic]int,
    body: []CST_Form,
) -> (int, bool) {
    if scope_places == nil || binding.name == "" ||
       field.name == "" || !type_supports_automatic_native_delete(field.ty) {
        return -1, false
    }
    place_name := fmt.tprintf("%s.%s", binding.name, field.name)
    aggregate_return_transfers_owner :=
        aggregate_result_body_transfers_name(
            lowering.emitter,
            body,
            binding.name,
        ) &&
        !aggregate_result_body_before_return_use_is_unsafe(
            lowering.emitter,
            body,
            binding.name,
        ) &&
        !aggregate_result_body_before_return_use_is_unsafe(
            lowering.emitter,
            body,
            place_name,
        )
    cleanup_unsupported := aggregate_return_transfers_owner ||
        body_deletes_or_returns_name(
            lowering.emitter,
            body,
            binding.name,
            true,
        ) ||
        body_assigns_name(body, binding.name) ||
        body_assigns_name(body, place_name) ||
        body_contains_result_capture(body, binding.name) ||
        body_contains_result_capture(body, place_name)
    place := ownership_ir_add_shadow_place(
        lowering,
        place_name,
        "delete",
        .Always,
        -1,
        .None,
        false,
        binding.target_span,
        field.ty,
        binding.name,
        cleanup_unsupported,
    )
    lowering.result.places[place].aggregate_return_transfers_owner =
        aggregate_return_transfers_owner
    append(scope_places, place)
    return place, true
}

ownership_ir_add_aggregate_return_events :: proc(
    lowering: ^Ownership_IR_Lowering,
    root_name: string,
    block: int,
    span: Span,
) {
    mapped_root := map_name(root_name)
    defer delete(mapped_root)
    prefix := fmt.tprintf("%s.", mapped_root)
    defer delete(prefix)
    emitted: [dynamic]int
    defer delete(emitted)
    for binding in lowering.names {
        if !strings.has_prefix(binding.name, prefix) ||
           ownership_ir_int_slice_contains(emitted[:], binding.place) ||
           binding.place < 0 ||
           binding.place >= len(lowering.result.places) ||
           !lowering.result.places[binding.place].aggregate_return_transfers_owner {
            continue
        }
        _ = ownership_ir_add_event(
            &lowering.result.graph,
            block,
            {kind = .Return, place = binding.place, span = span},
        )
        append(&emitted, binding.place)
    }
}

ownership_ir_add_composite_return_events :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
    block: int,
) {
    if form.kind == .Symbol {
        ownership_ir_add_aggregate_return_events(
            lowering,
            form.text,
            block,
            form.span,
        )
        if place, found := ownership_ir_lookup_name(lowering, form.text); found {
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {kind = .Return, place = place, span = form.span},
            )
        }
        return
    }
    if form.kind == .Vector || form.kind == .Set {
        for item in form.items {
            ownership_ir_add_composite_return_events(
                lowering,
                item,
                block,
            )
        }
        return
    }
}

ownership_ir_int_slice_contains :: proc(values: []int, candidate: int) -> bool {
    for value in values {
        if value == candidate {
            return true
        }
    }
    return false
}

ownership_ir_aggregate_alias_return_is_safe :: proc(
    lowering: ^Ownership_IR_Lowering,
    place: int,
    returned_root: string,
    bindings: []Binding,
    binding_index: int,
    body: []CST_Form,
) -> bool {
    if !aggregate_result_body_returns_name(body, returned_root) {
        return false
    }
    for binding in lowering.names {
        if binding.place != place {
            continue
        }
        dot := strings.last_index(binding.name, ".")
        if dot < 1 {
            continue
        }
        root := binding.name[:dot]
        for prior_index in 0..<binding_index {
            prior := bindings[prior_index].value
            if aggregate_result_name_use_is_unsafe(
                   lowering.emitter,
                   prior,
                   root,
               ) ||
               aggregate_result_name_use_is_unsafe(
                   lowering.emitter,
                   prior,
                   binding.name,
               ) {
                return false
            }
        }
        if aggregate_result_body_before_return_use_is_unsafe(
               lowering.emitter,
               body,
               root,
           ) ||
           aggregate_result_body_before_return_use_is_unsafe(
               lowering.emitter,
               body,
               binding.name,
           ) {
            return false
        }
    }
    return true
}

ownership_ir_bind_aggregate_alias :: proc(
    lowering: ^Ownership_IR_Lowering,
    alias, source: string,
    bindings: []Binding,
    binding_index: int,
    body: []CST_Form,
) {
    if alias == "" || source == "" {
        return
    }
    mapped_source := map_name(source)
    defer delete(mapped_source)
    prefix := fmt.tprintf("%s.", mapped_source)
    defer delete(prefix)
    initial_name_count := len(lowering.names)
    aliased_places: [dynamic]int
    defer delete(aliased_places)
    for index in 0..<initial_name_count {
        source_binding := lowering.names[index]
        if !strings.has_prefix(source_binding.name, prefix) {
            continue
        }
        suffix := source_binding.name[len(mapped_source):]
        alias_name := fmt.tprintf("%s%s", alias, suffix)
        ownership_ir_bind_name(lowering, alias_name, source_binding.place)
        delete(alias_name)
        if !ownership_ir_int_slice_contains(
            aliased_places[:],
            source_binding.place,
        ) {
            append(&aliased_places, source_binding.place)
        }
    }
    for place in aliased_places {
        if place < 0 || place >= len(lowering.result.places) ||
           !ownership_ir_aggregate_alias_return_is_safe(
               lowering,
               place,
               alias,
               bindings,
               binding_index,
               body,
           ) {
            continue
        }
        lowering.result.places[place].aggregate_return_transfers_owner = true
        lowering.result.places[place].aggregate_cleanup_unsupported = true
    }
}

ownership_ir_cleanup_arg_root_name :: proc(
    form: CST_Form,
) -> (string, bool) {
    if form.kind == .Symbol {
        root := form.text
        if len(root) > 0 && root[len(root)-1] == '^' {
            root = root[:len(root)-1]
        }
        return map_name(root), true
    }
    if form.kind != .List || len(form.items) != 2 ||
       form.items[0].kind != .Symbol ||
       (form.items[0].text != "addr" && form.items[0].text != "deref") {
        return "", false
    }
    return ownership_ir_cleanup_arg_root_name(form.items[1])
}

ownership_ir_has_aggregate_root :: proc(
    lowering: ^Ownership_IR_Lowering,
    root: string,
) -> bool {
    for place in lowering.result.places {
        if place.aggregate_root == root {
            return true
        }
    }
    return false
}

ownership_ir_call_has_tracked_aggregate_arg :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
) -> bool {
    for item in form.items[1:] {
        root, ok_root := ownership_ir_cleanup_arg_root_name(item)
        if !ok_root {
            continue
        }
        found := ownership_ir_has_aggregate_root(lowering, root)
        delete(root)
        if found {
            return true
        }
    }
    return false
}

ownership_ir_call_parameter_index :: proc(
    decl: ^Proc_Decl,
    args: []CST_Form,
    named_start, arg_index: int,
) -> (int, bool) {
    if decl == nil || arg_index < 0 || arg_index >= len(args) {
        return -1, false
    }
    if named_start < 0 || arg_index < named_start {
        if arg_index < len(decl.params) {
            return arg_index, true
        }
        return -1, false
    }
    named_offset := arg_index-named_start
    if named_offset%2 == 0 || arg_index == 0 {
        return -1, false
    }
    parameter_name, ok_name := brace_key_name(args[arg_index-1])
    if !ok_name {
        return -1, false
    }
    for parameter, parameter_index in decl.params {
        if parameter.name == parameter_name {
            return parameter_index, true
        }
    }
    return -1, false
}

ownership_ir_append_conditional_aggregate_cleanup_diagnostic :: proc(
    lowering: ^Ownership_IR_Lowering,
    subject: string,
    span: Span,
) {
    for diagnostic in lowering.result.diagnostic_candidates {
        if diagnostic.kind == .Explicit_Aggregate_Cleanup_Conditional &&
           diagnostic.subject == subject && diagnostic.span == span {
            return
        }
    }
    append(
        &lowering.result.diagnostic_candidates,
        Ownership_IR_Diagnostic_Fact{
            kind = .Explicit_Aggregate_Cleanup_Conditional,
            certainty = .Conservative,
            subject = strings.clone(subject),
            span = span,
        },
    )
}

ownership_ir_add_aggregate_cleanup_events :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
    called_proc: ^Proc_Decl,
    block: int,
    kind: Ownership_IR_Event_Kind,
    conditional := false,
) {
    if called_proc == nil ||
       (kind != .Destroy && kind != .Schedule_Destroy) {
        return
    }
    args := form.items[1:]
    named_start := first_keyword_arg_tail_start(args)
    for item, arg_index in args {
        parameter_index, ok_parameter := ownership_ir_call_parameter_index(
            called_proc,
            args,
            named_start,
            arg_index,
        )
        if !ok_parameter {
            continue
        }
        root, ok_root := ownership_ir_cleanup_arg_root_name(item)
        if !ok_root {
            continue
        }
        prefix := fmt.tprintf("%s.", root)
        for place in lowering.result.places {
            if place.aggregate_root != root ||
               !strings.has_prefix(place.name, prefix) {
                continue
            }
            field_name := place.name[len(prefix):]
            if strings.contains(field_name, ".") ||
               !procedure_may_clean_parameter_field(
                   called_proc,
                   parameter_index,
                   field_name,
               ) {
                continue
            }
            if !procedure_definitely_cleans_parameter_field(
                called_proc,
                parameter_index,
                field_name,
            ) {
                ownership_ir_append_conditional_aggregate_cleanup_diagnostic(
                    lowering,
                    place.name,
                    item.span,
                )
            }
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {
                    kind = kind,
                    place = place.place,
                    conditional = conditional,
                    span = item.span,
                },
            )
        }
        delete(prefix)
        delete(root)
    }
}

ownership_ir_lower_call :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
    block: int,
    store_binding := Binding{},
    scope_places: ^[dynamic]int = nil,
    store_body: []CST_Form = nil,
) {
    if form.kind != .List ||
       len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return
    }
    head := map_name(form.items[0].text)
    defer delete(head)
    struct_decl, struct_constructor := find_struct_decl(lowering.emitter, head)
    track_struct_fields := struct_constructor &&
                           !type_text_has_managed_lifecycle(
                               lowering.emitter,
                               struct_decl.name,
                           )
    has_tracked_arg := false
    for arg in form.items[1:] {
        if arg.kind == .Symbol {
            _, has_tracked_arg = ownership_ir_lookup_name(
                lowering,
                arg.text,
            )
        } else if arg.kind == .Brace {
            for pair_index := 1;
                pair_index < len(arg.items);
                pair_index += 2 {
                if arg.items[pair_index].kind != .Symbol {
                    continue
                }
                _, has_tracked_arg = ownership_ir_lookup_name(
                    lowering,
                    arg.items[pair_index].text,
                )
                if has_tracked_arg {
                    break
                }
            }
        }
        if has_tracked_arg {
            break
        }
    }
    if !has_tracked_arg {
        has_tracked_arg = ownership_ir_call_has_tracked_aggregate_arg(
            lowering,
            form,
        )
    }
    called_proc: ^Proc_Decl
    ok_called_proc := false
    if has_tracked_arg && !struct_constructor {
        _, called_proc, ok_called_proc = resolve_proc_call_decl(
            lowering.emitter,
            form.items[0].text,
        )
    }
    called_contract := Procedure_Ownership_Contract{}
    if ok_called_proc && called_proc != nil {
        called_contract = procedure_ownership_contract(
            called_proc,
            lowering.emitter,
        )
        ownership_ir_add_aggregate_cleanup_events(
            lowering,
            form,
            called_proc,
            block,
            .Destroy,
        )
    }
    defer procedure_ownership_contract_delete(&called_contract)
    args := form.items[1:]
    named_start := first_keyword_arg_tail_start(args)
    if place, found := ownership_ir_lookup_name(
        lowering,
        form.items[0].text,
    ); found {
        _ = ownership_ir_add_event(
            &lowering.result.graph,
            block,
            {
                kind = .Borrow,
                place = place,
                span = form.items[0].span,
            },
        )
    }
    for item, item_index in form.items[1:] {
        if named_start >= 0 && item_index >= named_start {
            named_offset := item_index-named_start
            if named_offset%2 == 0 {
                continue
            }
            field_name, ok_field := brace_key_name(
                args[item_index-1],
            )
            if item.kind != .Symbol {
                ownership_ir_lower_value_uses(lowering, item, block)
                continue
            }
            ownership_ir_lower_borrow_use(
                lowering,
                item.text,
                block,
                item.span,
            )
            place, found := ownership_ir_lookup_name(
                lowering,
                item.text,
            )
            if !found {
                continue
            }
            event_kind := Ownership_IR_Event_Kind.Borrow
            store_target := -1
            if struct_constructor {
                field_ty, known_field_ty := call_arg_expected_type(
                    lowering.emitter,
                    form,
                    item_index+1,
                )
                if known_field_ty {
                    cleanup_scheduled := false
                    for shadow_place in lowering.result.places {
                        if shadow_place.place == place {
                            cleanup_scheduled = shadow_place.cleanup_scheduled
                            break
                        }
                    }
                    if ownership_type_has_destructor(
                        lowering.emitter,
                        field_ty,
                    ) && !cleanup_scheduled {
                        event_kind = .Store
                    }
                    delete(field_ty)
                }
                if event_kind == .Store && track_struct_fields {
                    if field, ok_struct_field :=
                        ownership_ir_struct_field_for_call_arg(
                            lowering.emitter,
                            form,
                            item_index+1,
                        ); ok_struct_field {
                        if target, ok_target := ownership_ir_add_struct_field_place(
                            lowering,
                            store_binding,
                            field^,
                            scope_places,
                            store_body,
                        ); ok_target {
                            store_target = target
                        }
                    }
                }
            } else if ok_field && ok_called_proc && called_proc != nil &&
               procedure_ownership_contract_consumes_name(
                   &called_contract,
                   called_proc,
                   field_name,
               ) {
                event_kind = .Transfer
            }
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {
                    kind = event_kind,
                    place = place,
                    target = store_target if event_kind == .Store else 0,
                    span = item.span,
                },
            )
            continue
        }
        if item.kind == .List {
            ownership_ir_lower_call(lowering, item, block)
            continue
        }
        if item.kind == .Brace {
            for pair_index := 0;
                pair_index+1 < len(item.items);
                pair_index += 2 {
                field_name, ok_field := brace_key_name(
                    item.items[pair_index],
                )
                value := item.items[pair_index+1]
                if value.kind != .Symbol {
                    ownership_ir_lower_value_uses(
                        lowering,
                        value,
                        block,
                    )
                    continue
                }
                ownership_ir_lower_borrow_use(
                    lowering,
                    value.text,
                    block,
                    value.span,
                )
                place, found := ownership_ir_lookup_name(
                    lowering,
                    value.text,
                )
                if !found {
                    continue
                }
                event_kind := Ownership_IR_Event_Kind.Borrow
                if ok_field && ok_called_proc && called_proc != nil &&
                   procedure_ownership_contract_consumes_name(
                       &called_contract,
                       called_proc,
                       field_name,
                   ) {
                    event_kind = .Transfer
                }
                _ = ownership_ir_add_event(
                    &lowering.result.graph,
                    block,
                    {
                        kind = event_kind,
                        place = place,
                        span = value.span,
                    },
                )
            }
            continue
        }
        if item.kind == .Vector || item.kind == .Set {
            ownership_ir_lower_value_uses(lowering, item, block)
            continue
        }
        if item.kind != .Symbol {
            continue
        }
        ownership_ir_lower_borrow_use(
            lowering,
            item.text,
            block,
            item.span,
        )
        place, found := ownership_ir_lookup_name(lowering, item.text)
        if !found {
            continue
        }
        event_kind := Ownership_IR_Event_Kind.Borrow
        for shadow_place in lowering.result.places {
            if shadow_place.place == place &&
               (shadow_place.cleanup_head == head ||
                (shadow_place.diagnose_unreleased &&
                 cleanup_call_head(head))) {
                event_kind = .Destroy
                break
            }
        }
        if event_kind == .Borrow && struct_constructor {
            field_ty, known_field_ty := call_arg_expected_type(
                lowering.emitter,
                form,
                item_index+1,
            )
            if known_field_ty {
                cleanup_scheduled := false
                for shadow_place in lowering.result.places {
                    if shadow_place.place == place {
                        cleanup_scheduled = shadow_place.cleanup_scheduled
                        break
                    }
                }
                if ownership_type_has_destructor(lowering.emitter, field_ty) &&
                   !cleanup_scheduled {
                    event_kind = .Store
                }
                delete(field_ty)
            }
        }
        if event_kind == .Borrow &&
           form_transfers_owned_args(form) &&
           item_index+1 >= 2 {
            event_kind = .Transfer
        }
        if event_kind == .Borrow &&
           ((ok_called_proc && called_proc != nil &&
             procedure_ownership_contract_consumes(
                 &called_contract,
                 item_index,
             )) ||
            call_arg_targets_owned_param(
                lowering.emitter,
                form,
                item_index+1,
            ) ||
            call_arg_transfers_owned_result(
                lowering.emitter,
                form,
                item_index+1,
            )) {
            event_kind = .Transfer
        }
        store_target := -1
        if event_kind == .Store && track_struct_fields {
            if field, ok_field := ownership_ir_struct_field_for_call_arg(
                lowering.emitter,
                form,
                item_index+1,
            ); ok_field {
                if target, ok_target := ownership_ir_add_struct_field_place(
                    lowering,
                    store_binding,
                    field^,
                    scope_places,
                    store_body,
                ); ok_target {
                    store_target = target
                }
            }
        }
        _ = ownership_ir_add_event(
            &lowering.result.graph,
            block,
            {
                kind = event_kind,
                place = place,
                target = store_target if event_kind == .Store else 0,
                span = item.span,
            },
        )
    }
    _ = ownership_ir_add_event(
        &lowering.result.graph,
        block,
        {kind = .Call, span = form.span},
    )
}

ownership_ir_lower_value_uses :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
    block: int,
) {
    if form.kind == .Symbol {
        ownership_ir_lower_borrow_use(
            lowering,
            form.text,
            block,
            form.span,
        )
        if place, found := ownership_ir_lookup_name(
            lowering,
            form.text,
        ); found {
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {kind = .Borrow, place = place, span = form.span},
            )
        }
        return
    }
    if form.kind == .List {
        if len(form.items) >= 3 && form.items[0].kind == .Symbol &&
           form.items[0].text == "if" {
            ownership_ir_lower_value_uses(
                lowering,
                form.items[1],
                block,
            )
            for branch in form.items[2:] {
                if !ownership_ir_form_never_returns(
                    lowering.emitter,
                    branch,
                ) {
                    ownership_ir_lower_value_uses(
                        lowering,
                        branch,
                        block,
                    )
                }
            }
            return
        }
        ownership_ir_lower_call(lowering, form, block)
        return
    }
    for item in form.items {
        ownership_ir_lower_value_uses(lowering, item, block)
    }
}

ownership_ir_deferred_cleanup_arg_place :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
) -> (int, bool) {
    if form.kind == .Symbol {
        return ownership_ir_lookup_name(lowering, form.text)
    }
    if form.kind != .List || len(form.items) != 2 ||
       form.items[0].kind != .Symbol {
        return -1, false
    }
    head := form.items[0].text
    if head != "addr" && head != "deref" {
        return -1, false
    }
    return ownership_ir_deferred_cleanup_arg_place(
        lowering,
        form.items[1],
    )
}

ownership_ir_schedule_deferred_form :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
    block: int,
    conditional: bool,
) {
    if form.kind != .List ||
       len(form.items) == 0 ||
       form.items[0].kind != .Symbol {
        return
    }
    raw_head := form.items[0].text
    switch raw_head {
    case "do", "block":
        for item in form.items[1:] {
            ownership_ir_schedule_deferred_form(
                lowering,
                item,
                block,
                conditional,
            )
        }
        return
    case "if":
        for item in form.items[2:] {
            ownership_ir_schedule_deferred_form(
                lowering,
                item,
                block,
                true,
            )
        }
        return
    }

    head := map_name(raw_head)
    defer delete(head)
    if _, called_proc, ok_called_proc := resolve_proc_call_decl(
        lowering.emitter,
        raw_head,
    ); ok_called_proc && called_proc != nil {
        ownership_ir_add_aggregate_cleanup_events(
            lowering,
            form,
            called_proc,
            block,
            .Schedule_Destroy,
            conditional,
        )
    }
    for item in form.items[1:] {
        place, found := ownership_ir_deferred_cleanup_arg_place(
            lowering,
            item,
        )
        if !found {
            continue
        }
        for shadow_place in lowering.result.places {
            if shadow_place.place != place ||
               (shadow_place.cleanup_head != head &&
                !((shadow_place.cleanup_head != "" ||
                   shadow_place.diagnose_unreleased) &&
                  (head == "delete" || cleanup_call_head(head)))) {
                continue
            }
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {
                    kind = .Schedule_Destroy,
                    place = place,
                    conditional = conditional,
                    span = item.span,
                },
            )
            break
        }
    }
}

ownership_ir_wrap_scope_exits :: proc(
    lowering: ^Ownership_IR_Lowering,
    body_flow: Ownership_IR_Flow,
    scope_places: []int,
    outer_borrow_count: int,
    scope_span: Span,
) -> Ownership_IR_Flow {
    result := Ownership_IR_Flow{}
    for exit in body_flow.exits {
        boundary := ownership_ir_add_block(&lowering.result.graph)
        _ = ownership_ir_add_successor(
            &lowering.result.graph,
            exit.block,
            boundary,
        )
        if exit.kind != .Return {
            borrow_limit := min(
                outer_borrow_count,
                len(lowering.borrows),
            )
            for borrow_index in 0..<borrow_limit {
                borrower := lowering.borrows[borrow_index].place
                for owner in scope_places {
                    _ = ownership_ir_add_event(
                        &lowering.result.graph,
                        boundary,
                        {
                            kind = .Borrow_Owner_Exit,
                            place = borrower,
                            target = owner,
                            span = scope_span if exit.kind == .Fallthrough else exit.span,
                        },
                    )
                }
            }
        }
        for place in scope_places {
            // Synthetic fallthrough has no source form of its own. The
            // owning scope is its stable cleanup emission site.
            append(
                &lowering.result.places[place].scope_exits,
                Ownership_IR_Exit{
                    kind = exit.kind,
                    source = exit.source,
                    block = boundary,
                    span = scope_span if exit.kind == .Fallthrough else exit.span,
                    source_form = exit.source_form,
                },
            )
        }
        if exit.kind == .Fallthrough {
            continuation := ownership_ir_add_block(&lowering.result.graph)
            _ = ownership_ir_add_successor(
                &lowering.result.graph,
                boundary,
                continuation,
            )
            ownership_ir_flow_append(
                &result,
                {kind = .Fallthrough, block = continuation},
            )
        } else {
            ownership_ir_flow_append(
                &result,
                {
                    kind = exit.kind,
                    source = exit.source,
                    block = boundary,
                    span = exit.span,
                    source_form = exit.source_form,
                },
            )
        }
    }
    return result
}

ownership_ir_merge_branches :: proc(
    lowering: ^Ownership_IR_Lowering,
    left, right: Ownership_IR_Flow,
) -> Ownership_IR_Flow {
    result := Ownership_IR_Flow{}
    join := -1
    for exit in left.exits {
        if exit.kind == .Fallthrough {
            if join < 0 {
                join = ownership_ir_add_block(&lowering.result.graph)
            }
            _ = ownership_ir_add_successor(
                &lowering.result.graph,
                exit.block,
                join,
            )
        } else {
            ownership_ir_flow_append(&result, exit)
        }
    }
    for exit in right.exits {
        if exit.kind == .Fallthrough {
            if join < 0 {
                join = ownership_ir_add_block(&lowering.result.graph)
            }
            _ = ownership_ir_add_successor(
                &lowering.result.graph,
                exit.block,
                join,
            )
        } else {
            ownership_ir_flow_append(&result, exit)
        }
    }
    if join >= 0 {
        ownership_ir_flow_append(
            &result,
            {kind = .Fallthrough, block = join},
        )
    }
    return result
}

ownership_ir_lower_multiway_branches :: proc(
    lowering: ^Ownership_IR_Lowering,
    branches: []CST_Form,
    block: int,
    can_transfer: bool,
) -> Ownership_IR_Flow {
    result := Ownership_IR_Flow{}
    join := -1
    for branch in branches {
        branch_block := ownership_ir_add_block(&lowering.result.graph)
        _ = ownership_ir_add_successor(
            &lowering.result.graph,
            block,
            branch_block,
        )
        branch_flow := ownership_ir_lower_form(
            lowering,
            branch,
            branch_block,
            can_transfer,
        )
        for exit in branch_flow.exits {
            if exit.kind == .Fallthrough {
                if join < 0 {
                    join = ownership_ir_add_block(&lowering.result.graph)
                }
                _ = ownership_ir_add_successor(
                    &lowering.result.graph,
                    exit.block,
                    join,
                )
            } else {
                ownership_ir_flow_append(&result, exit)
            }
        }
        ownership_ir_flow_delete(&branch_flow)
    }
    if join >= 0 {
        ownership_ir_flow_append(
            &result,
            {kind = .Fallthrough, block = join},
        )
    }
    return result
}

ownership_ir_lower_loop :: proc(
    lowering: ^Ownership_IR_Lowering,
    condition: CST_Form,
    body: []CST_Form,
    block: int,
) -> Ownership_IR_Flow {
    header := ownership_ir_add_block(&lowering.result.graph)
    body_entry := ownership_ir_add_block(&lowering.result.graph)
    after_loop := ownership_ir_add_block(&lowering.result.graph)
    _ = ownership_ir_add_successor(&lowering.result.graph, block, header)
    ownership_ir_lower_value_uses(lowering, condition, header)
    _ = ownership_ir_add_successor(&lowering.result.graph, header, body_entry)
    _ = ownership_ir_add_successor(&lowering.result.graph, header, after_loop)

    body_flow := ownership_ir_lower_forms(
        lowering,
        body,
        body_entry,
        false,
    )
    defer ownership_ir_flow_delete(&body_flow)
    result := ownership_ir_flow_single(after_loop)
    for exit in body_flow.exits {
        switch exit.kind {
        case .Fallthrough, .Continue:
            _ = ownership_ir_add_successor(
                &lowering.result.graph,
                exit.block,
                header,
            )
        case .Break:
            _ = ownership_ir_add_successor(
                &lowering.result.graph,
                exit.block,
                after_loop,
            )
        case .Return:
            ownership_ir_flow_append(&result, exit)
        }
    }
    return result
}

ownership_ir_lower_borrow_escapes :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
    block: int,
) {
    if form.kind == .Symbol {
        if borrower, found := ownership_ir_lookup_borrow_name(
            lowering,
            form.text,
        ); found {
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {
                    kind = .Borrow_Escape,
                    place = borrower,
                    target = -1,
                    span = form.span,
                },
            )
        }
        return
    }
    if owner_name, found := form_direct_borrow_owner_name(
        form,
        lowering.emitter,
    ); found {
        defer delete(owner_name)
        if owner, has_owner := ownership_ir_lookup_name(
            lowering,
            owner_name,
        ); has_owner {
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {
                    kind = .Borrow_Escape,
                    place = -1,
                    target = owner,
                    span = form.span,
                },
            )
            return
        }
        if borrower, has_borrower := ownership_ir_lookup_borrow_name(
            lowering,
            owner_name,
        ); has_borrower {
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {
                    kind = .Borrow_Escape,
                    place = borrower,
                    target = -1,
                    span = form.span,
                },
            )
        }
        return
    }
    if form.kind == .Vector || form.kind == .Set {
        for item in form.items {
            ownership_ir_lower_borrow_escapes(lowering, item, block)
        }
        return
    }
    if form.kind == .Brace {
        for index := 1; index < len(form.items); index += 2 {
            ownership_ir_lower_borrow_escapes(
                lowering,
                form.items[index],
                block,
            )
        }
        return
    }
    if !form_is_struct_or_union_constructor(lowering.emitter, form) {
        return
    }
    args := form.items[1:]
    if keyword_arg_tail_is_syntax(args, 0) {
        for index := 1; index < len(args); index += 2 {
            ownership_ir_lower_borrow_escapes(
                lowering,
                args[index],
                block,
            )
        }
        return
    }
    for arg in args {
        ownership_ir_lower_borrow_escapes(lowering, arg, block)
    }
}

ownership_ir_form_never_returns :: proc(
    e: ^Emitter,
    form: CST_Form,
    depth := 0,
) -> bool {
    if e == nil || depth > 16 || form.kind != .List ||
       len(form.items) == 0 || form.items[0].kind != .Symbol {
        return false
    }
    head := form.items[0].text
    switch head {
    case "do", "block":
        for item in form.items[1:] {
            if ownership_ir_form_never_returns(e, item, depth+1) {
                return true
            }
        }
        return false
    case "let":
        if len(form.items) < 3 {
            return false
        }
        for item in form.items[2:] {
            if ownership_ir_form_never_returns(e, item, depth+1) {
                return true
            }
        }
        return false
    case "if":
        return len(form.items) >= 4 &&
               ownership_ir_form_never_returns(e, form.items[2], depth+1) &&
               ownership_ir_form_never_returns(e, form.items[3], depth+1)
    }
    if imported_interop_call_matches(e, head, "core:os", "exit") {
        return true
    }
    mapped_head := map_name(head)
    defer delete(mapped_head)
    proc_decl, found := find_proc_decl(e, mapped_head)
    if !found || len(proc_decl.body) == 0 {
        return false
    }
    for item in proc_decl.body {
        if ownership_ir_form_never_returns(e, item, depth+1) {
            return true
        }
    }
    return false
}

ownership_ir_lower_form :: proc(
    lowering: ^Ownership_IR_Lowering,
    form: CST_Form,
    block: int,
    can_transfer: bool,
) -> Ownership_IR_Flow {
    if form.kind == .Symbol {
        if can_transfer {
            ownership_ir_lower_borrow_escapes(lowering, form, block)
            ownership_ir_add_aggregate_return_events(
                lowering,
                form.text,
                block,
                form.span,
            )
        }
        if !can_transfer {
            ownership_ir_lower_borrow_use(
                lowering,
                form.text,
                block,
                form.span,
            )
        }
        if place, found := ownership_ir_lookup_name(lowering, form.text); found {
            kind := Ownership_IR_Event_Kind.Return if can_transfer else .Borrow
            _ = ownership_ir_add_event(
                &lowering.result.graph,
                block,
                {kind = kind, place = place, span = form.span},
            )
        }
        return ownership_ir_tail_flow(block, form, can_transfer)
    }
    if form.kind != .List || len(form.items) == 0 || form.items[0].kind != .Symbol {
        if can_transfer {
            ownership_ir_lower_borrow_escapes(lowering, form, block)
            ownership_ir_add_composite_return_events(lowering, form, block)
        } else {
            ownership_ir_lower_discarded_result(lowering, form, block)
        }
        return ownership_ir_tail_flow(block, form, can_transfer)
    }

    head := form.items[0].text
    switch head {
    case "quote", "quasiquote", "fn":
        return ownership_ir_tail_flow(block, form, can_transfer)
    case "do", "block":
        if len(form.items) == 1 {
            return ownership_ir_flow_single(
                block,
                .Return if can_transfer else .Fallthrough,
            )
        }
        return ownership_ir_lower_forms(
            lowering,
            form.items[1:],
            block,
            can_transfer,
        )
    case "let":
        if len(form.items) < 3 {
            return ownership_ir_flow_single(block)
        }
        bindings, _, ok_bindings := parse_let_bindings(form.items[1])
        if !ok_bindings {
            return ownership_ir_flow_single(block)
        }
        defer delete(bindings)
        name_start := len(lowering.names)
        borrow_start := len(lowering.borrows)
        scope_places: [dynamic]int
        defer delete(scope_places)
        for binding, binding_index in bindings {
            ownership_ir_lower_binding(
                lowering,
                binding,
                bindings[:],
                binding_index,
                form.items[2:],
                block,
                &scope_places,
            )
        }
        body_flow := ownership_ir_lower_forms(
            lowering,
            form.items[2:],
            block,
            can_transfer,
        )
        result := Ownership_IR_Flow{}
        if len(scope_places) == 0 {
            result = body_flow
            body_flow = {}
        } else {
            result = ownership_ir_wrap_scope_exits(
                lowering,
                body_flow,
                scope_places[:],
                borrow_start,
                form.span,
            )
        }
        ownership_ir_flow_delete(&body_flow)
        for index := name_start; index < len(lowering.names); index += 1 {
            delete(lowering.names[index].name)
        }
        resize(&lowering.names, name_start)
        for index := borrow_start; index < len(lowering.borrows); index += 1 {
            delete(lowering.borrows[index].name)
        }
        resize(&lowering.borrows, borrow_start)
        return result
    case "if":
        if len(form.items) < 3 {
            return ownership_ir_flow_single(block)
        }
        ownership_ir_lower_value_uses(lowering, form.items[1], block)
        then_block := ownership_ir_add_block(&lowering.result.graph)
        else_block := ownership_ir_add_block(&lowering.result.graph)
        _ = ownership_ir_add_successor(&lowering.result.graph, block, then_block)
        _ = ownership_ir_add_successor(&lowering.result.graph, block, else_block)
        then_flow := ownership_ir_lower_form(
            lowering,
            form.items[2],
            then_block,
            can_transfer,
        )
        defer ownership_ir_flow_delete(&then_flow)
        else_flow := ownership_ir_flow_single(
            else_block,
            .Return if can_transfer else .Fallthrough,
        )
        defer ownership_ir_flow_delete(&else_flow)
        if len(form.items) >= 4 {
            ownership_ir_flow_delete(&else_flow)
            else_flow = ownership_ir_lower_form(
                lowering,
                form.items[3],
                else_block,
                can_transfer,
            )
        }
        return ownership_ir_merge_branches(lowering, then_flow, else_flow)
    case "type-case", "match":
        if len(form.items) < 4 {
            return ownership_ir_flow_single(block)
        }
        ownership_ir_lower_value_uses(lowering, form.items[1], block)
        branches: [dynamic]CST_Form
        defer delete(branches)
        for branch_index := 3;
            branch_index < len(form.items)-1;
            branch_index += 2 {
            append(&branches, form.items[branch_index])
        }
        append(&branches, form.items[len(form.items)-1])
        return ownership_ir_lower_multiway_branches(
            lowering,
            branches[:],
            block,
            can_transfer,
        )
    case "while":
        if len(form.items) < 3 {
            return ownership_ir_flow_single(block)
        }
        return ownership_ir_lower_loop(
            lowering,
            form.items[1],
            form.items[2:],
            block,
        )
    case "for":
        if len(form.items) < 3 || form.items[1].kind != .Vector {
            return ownership_ir_flow_single(block)
        }
        binding := form.items[1]
        return ownership_ir_lower_loop(
            lowering,
            binding,
            form.items[2:],
            block,
        )
    case "return":
        for item in form.items[1:] {
            ownership_ir_lower_borrow_escapes(lowering, item, block)
            if item.kind != .Symbol {
                ownership_ir_lower_value_uses(lowering, item, block)
            }
        }
        // Return operands are all evaluated before their values leave the
        // procedure. Record their reads first so a value returned in an early
        // slot may still be used to compute a later slot.
        for item in form.items[1:] {
            if item.kind != .Symbol {
                ownership_ir_add_composite_return_events(
                    lowering,
                    item,
                    block,
                )
                continue
            }
            ownership_ir_add_aggregate_return_events(
                lowering,
                item.text,
                block,
                item.span,
            )
            if place, found := ownership_ir_lookup_name(lowering, item.text); found {
                _ = ownership_ir_add_event(
                    &lowering.result.graph,
                    block,
                    {kind = .Return, place = place, span = item.span},
                )
            }
        }
        return ownership_ir_flow_single(
            block,
            .Return,
            form.span,
            form,
            .Explicit,
        )
    case "discard":
        for item in form.items[1:] {
            ownership_ir_lower_value_uses(lowering, item, block)
            ownership_ir_lower_discarded_result(lowering, item, block)
        }
        return ownership_ir_flow_single(block)
    case "break":
        return ownership_ir_flow_single(
            block,
            .Break,
            form.span,
            form,
            .Explicit,
        )
    case "continue":
        return ownership_ir_flow_single(
            block,
            .Continue,
            form.span,
            form,
            .Explicit,
        )
    case "set!":
        if len(form.items) == 3 {
            target := -1
            found_target := false
            borrow_target := -1
            found_borrow_target := false
            if form.items[1].kind == .Symbol {
                target, found_target = ownership_ir_lookup_name(
                    lowering,
                    form.items[1].text,
                )
                borrow_target, found_borrow_target =
                    ownership_ir_lookup_borrow_name(
                        lowering,
                        form.items[1].text,
                    )
            }
            if form.items[2].kind == .Symbol {
                source, found_source := ownership_ir_lookup_name(
                    lowering,
                    form.items[2].text,
                )
                if found_source && (!found_target || target != source) {
                    _ = ownership_ir_add_event(
                        &lowering.result.graph,
                        block,
                        {
                            kind = .Store,
                            place = source,
                            target = -1,
                            span = form.items[2].span,
                        },
                    )
                }
            } else {
                ownership_ir_lower_value_uses(
                    lowering,
                    form.items[2],
                    block,
                )
            }
            if found_target {
                _ = ownership_ir_add_event(
                    &lowering.result.graph,
                    block,
                    {
                        kind = .Reassign,
                        place = target,
                        span = form.items[1].span,
                    },
                )
            }
            if found_borrow_target {
                ownership_ir_lower_borrow_assignment(
                    lowering,
                    borrow_target,
                    form.items[2],
                    block,
                )
            }
        }
        return ownership_ir_flow_single(block)
    case "delete":
        for item in form.items[1:] {
            ownership_ir_lower_borrow_delete(lowering, item, block)
            if item.kind != .Symbol {
                continue
            }
            if place, found := ownership_ir_lookup_name(lowering, item.text); found {
                _ = ownership_ir_add_event(
                    &lowering.result.graph,
                    block,
                    {kind = .Destroy, place = place, span = item.span},
                )
            }
        }
        return ownership_ir_flow_single(block)
    case "defer", "errdefer":
        for item in form.items[1:] {
            ownership_ir_schedule_deferred_form(
                lowering,
                item,
                block,
                head == "errdefer",
            )
        }
        return ownership_ir_flow_single(block)
    }
    ownership_ir_lower_call(lowering, form, block)
    if ownership_ir_form_never_returns(lowering.emitter, form) {
        return ownership_ir_flow_single(
            block,
            .Return,
            form.span,
            form,
            .Synthetic,
        )
    }
    if can_transfer {
        ownership_ir_lower_borrow_escapes(lowering, form, block)
    }
    if can_transfer &&
       form_value_arity(lowering.emitter, form) == .Single {
        return ownership_ir_tail_flow(block, form, true)
    }
    if !can_transfer {
        ownership_ir_lower_discarded_result(lowering, form, block)
    }
    return ownership_ir_flow_single(
        block,
        .Return if can_transfer else .Fallthrough,
    )
}

ownership_ir_lower_forms :: proc(
    lowering: ^Ownership_IR_Lowering,
    forms: []CST_Form,
    block: int,
    can_transfer_final: bool,
) -> Ownership_IR_Flow {
    current := ownership_ir_flow_single(block)
    for form, index in forms {
        next := Ownership_IR_Flow{}
        for exit in current.exits {
            if exit.kind != .Fallthrough {
                ownership_ir_flow_append(&next, exit)
                continue
            }
            lowered := ownership_ir_lower_form(
                lowering,
                form,
                exit.block,
                can_transfer_final && index == len(forms)-1,
            )
            for lowered_exit in lowered.exits {
                ownership_ir_flow_append(&next, lowered_exit)
            }
            ownership_ir_flow_delete(&lowered)
        }
        ownership_ir_flow_delete(&current)
        current = next
    }
    return current
}

ownership_ir_lower_proc :: proc(
    e: ^Emitter,
    decl: ^Proc_Decl,
) -> Ownership_IR_Shadow_Proc {
    return_count := 0
    #partial switch decl.returns.kind {
    case .Single:
        return_count = 1
    case .Named:
        return_count = len(decl.returns.named)
    case .None:
    }
    lowering := Ownership_IR_Lowering{
        emitter = e,
        result = {
            name = strings.clone(decl.name),
            return_count = return_count,
            graph = {entry = 0},
        },
    }
    defer ownership_ir_lowering_delete(&lowering)
    entry := ownership_ir_add_block(&lowering.result.graph)
    flow := ownership_ir_lower_forms(
        &lowering,
        decl.body[:],
        entry,
        decl.returns.kind != .None,
    )
    ownership_ir_flow_delete(&flow)
    return lowering.result
}

ownership_ir_plan_proc :: proc(
    e: ^Emitter,
    decl: ^Proc_Decl,
) -> (Ownership_IR_Shadow_Proc, Ownership_IR_Cleanup_Plan) {
    shadow := ownership_ir_lower_proc(e, decl)
    analysis := ownership_ir_analyze(shadow.graph)
    plan := ownership_ir_build_cleanup_plan(shadow, analysis)
    needs_value_liveness := false
    for place in shadow.places {
        if place.diagnose_use_after_transfer ||
           place.diagnose_discarded_result {
            needs_value_liveness = true
            break
        }
    }
    if needs_value_liveness {
        value_analysis := ownership_ir_analyze_value_liveness(shadow.graph)
        ownership_ir_append_value_diagnostics(
            shadow,
            value_analysis,
            &plan,
        )
        ownership_ir_analysis_delete(&value_analysis)
    }
    borrow_analysis := ownership_ir_analyze_borrows(shadow.graph)
    ownership_ir_append_borrow_diagnostics(
        shadow,
        borrow_analysis,
        &plan,
    )
    ownership_ir_borrow_analysis_delete(&borrow_analysis)
    ownership_ir_analysis_delete(&analysis)
    return shadow, plan
}

ownership_ir_event_requires_live_value :: proc(
    kind: Ownership_IR_Event_Kind,
) -> bool {
    #partial switch kind {
    case .Borrow, .Copy, .Move, .Store, .Destroy, .Transfer, .Return:
        return true
    case .Acquire, .Reassign, .Schedule_Destroy, .Discard, .Call,
         .Borrow_Assign, .Borrow_Copy, .Borrow_Clear, .Borrow_Escape,
         .Borrow_Use, .Borrow_Delete, .Borrow_Owner_Exit:
        return false
    }
    return false
}

ownership_ir_owner_released_at_boundary :: proc(
    result: Ownership_IR_Shadow_Proc,
    plan: Ownership_IR_Cleanup_Plan,
    owner, block: int,
) -> bool {
    for action in plan.actions {
        if action.place == owner && action.block == block &&
           action.reachable && action.need != .None {
            return true
        }
    }
    for place in result.places {
        if place.place == owner && place.cleanup_scheduled {
            return true
        }
    }
    for graph_block in result.graph.blocks {
        for event in graph_block.events {
            if event.kind == .Schedule_Destroy && event.place == owner {
                return true
            }
        }
    }
    return false
}

ownership_ir_append_borrowed_escape_diagnostic :: proc(
    result: Ownership_IR_Shadow_Proc,
    plan: ^Ownership_IR_Cleanup_Plan,
    owner: int,
    span: Span,
) {
    if plan == nil || owner < 0 {
        return
    }
    for place in result.places {
        if place.place != owner ||
           place.borrowed_provenance || place.name == "" {
            continue
        }
        for diagnostic in plan.diagnostics {
            if diagnostic.kind == .Borrowed_Escape &&
               diagnostic.subject == place.name &&
               diagnostic.span == span {
                return
            }
        }
        append(&plan.diagnostics, Ownership_IR_Diagnostic_Fact{
            kind = .Borrowed_Escape,
            certainty = .Conservative,
            subject = strings.clone(place.name),
            span = span,
        })
        return
    }
}

ownership_ir_append_borrowed_use_after_destroy_diagnostic :: proc(
    result: Ownership_IR_Shadow_Proc,
    plan: ^Ownership_IR_Cleanup_Plan,
    invalid_owners: []bool,
    invalid_fact: Ownership_IR_Borrow_Invalid_Fact,
    borrower, place_count: int,
    span: Span,
) -> bool {
    if plan == nil || !invalid_fact.may_invalid ||
       borrower < 0 || borrower >= place_count {
        return false
    }
    owner := -1
    start := borrower*place_count
    if start >= 0 && start+place_count <= len(invalid_owners) {
        for invalid, candidate in invalid_owners[start:start+place_count] {
            if invalid {
                owner = candidate
                break
            }
        }
    }
    if owner < 0 {
        return false
    }
    for place in result.places {
        if place.place != owner || place.borrowed_provenance ||
           place.name == "" {
            continue
        }
        append(&plan.diagnostics, Ownership_IR_Diagnostic_Fact{
            kind = .Borrowed_Use_After_Destroy,
            certainty = .Definite if invalid_fact.must_invalid else .Conservative,
            subject = strings.clone(place.name),
            span = span,
        })
        return true
    }
    return false
}

ownership_ir_append_borrow_diagnostics :: proc(
    result: Ownership_IR_Shadow_Proc,
    analysis: Ownership_IR_Borrow_Analysis,
    plan: ^Ownership_IR_Cleanup_Plan,
) {
    if plan == nil || !analysis.valid || !analysis.converged {
        return
    }
    place_count := result.graph.place_count
    for block, block_index in result.graph.blocks {
        if block_index >= len(analysis.blocks) ||
           !analysis.blocks[block_index].reachable {
            continue
        }
        owners := make(
            [dynamic]bool,
            len(analysis.blocks[block_index].entry_owners),
        )
        copy(
            owners[:],
            analysis.blocks[block_index].entry_owners[:],
        )
        invalid_owners := make(
            [dynamic]bool,
            len(analysis.blocks[block_index].entry_invalid_owners),
        )
        copy(
            invalid_owners[:],
            analysis.blocks[block_index].entry_invalid_owners[:],
        )
        facts := make(
            [dynamic]Ownership_IR_Borrow_Fact,
            len(analysis.blocks[block_index].entry),
        )
        copy(facts[:], analysis.blocks[block_index].entry[:])
        invalid_facts := make(
            [dynamic]Ownership_IR_Borrow_Invalid_Fact,
            len(analysis.blocks[block_index].entry_invalid),
        )
        copy(
            invalid_facts[:],
            analysis.blocks[block_index].entry_invalid[:],
        )
        valid := true
        for event in block.events {
            if event.kind == .Borrow_Owner_Exit &&
               event.place >= 0 && event.place < place_count &&
               event.target >= 0 && event.target < place_count &&
               ownership_ir_owner_released_at_boundary(
                   result,
                   plan^,
                   event.target,
                   block_index,
               ) {
                relation := event.place*place_count+event.target
                if relation >= 0 && relation < len(owners) &&
                   owners[relation] {
                    ownership_ir_append_borrowed_escape_diagnostic(
                        result,
                        plan,
                        event.target,
                        event.span,
                    )
                }
            }
            if event.kind == .Borrow_Use &&
               event.place >= 0 && event.place < place_count {
                _ = ownership_ir_append_borrowed_use_after_destroy_diagnostic(
                    result,
                    plan,
                    invalid_owners[:],
                    invalid_facts[event.place],
                    event.place,
                    place_count,
                    event.span,
                )
            }
            if event.kind == .Borrow_Delete &&
               event.place >= 0 && event.place < place_count {
                borrow_fact := facts[event.place]
                if borrow_fact.may_borrowed {
                    for place in result.places {
                        if place.place != event.place ||
                           !place.borrowed_provenance || place.name == "" {
                            continue
                        }
                        append(&plan.diagnostics, Ownership_IR_Diagnostic_Fact{
                            kind = .Borrowed_Delete_Result if place.transient else .Borrowed_Delete_Local,
                            certainty = .Definite if borrow_fact.must_borrowed else .Conservative,
                            subject = strings.clone(place.name),
                            span = event.span,
                        })
                        break
                    }
                }
            }
            if event.kind == .Borrow_Escape {
                invalid_escape := false
                if event.place >= 0 && event.place < place_count {
                    invalid_escape =
                        ownership_ir_append_borrowed_use_after_destroy_diagnostic(
                            result,
                            plan,
                            invalid_owners[:],
                            invalid_facts[event.place],
                            event.place,
                            place_count,
                            event.span,
                        )
                }
                owner := event.target
                if event.place >= 0 && !invalid_escape {
                    owner = -1
                    start := event.place*place_count
                    if start >= 0 && start+place_count <= len(owners) {
                        for borrowed, candidate in owners[start:start+place_count] {
                            if borrowed {
                                owner = candidate
                                break
                            }
                        }
                    }
                }
                if owner >= 0 && !invalid_escape {
                    ownership_ir_append_borrowed_escape_diagnostic(
                        result,
                        plan,
                        owner,
                        event.span,
                    )
                }
            }
            ownership_ir_apply_borrow_event(
                event,
                &owners,
                &facts,
                &invalid_owners,
                &invalid_facts,
                place_count,
                &valid,
            )
        }
        delete(owners)
        delete(invalid_owners)
        delete(facts)
        delete(invalid_facts)
        if !valid {
            return
        }
    }
}

ownership_ir_append_value_diagnostics :: proc(
    result: Ownership_IR_Shadow_Proc,
    analysis: Ownership_IR_Analysis,
    plan: ^Ownership_IR_Cleanup_Plan,
) {
    if plan == nil || !analysis.valid || !analysis.converged {
        return
    }
    for block, block_index in result.graph.blocks {
        if block_index >= len(analysis.blocks) ||
           !analysis.blocks[block_index].reachable {
            continue
        }
        facts: [dynamic]Ownership_IR_Live_Fact
        ownership_ir_copy_facts(
            &facts,
            analysis.blocks[block_index].entry[:],
        )
        valid := true
        for event in block.events {
            place_name := ""
            diagnostic_place: ^Ownership_IR_Shadow_Place
            if event.place >= 0 && event.place < len(facts) {
                for &place in result.places {
                    if place.place == event.place {
                        diagnostic_place = &place
                    }
                    if place.place == event.place &&
                       place.diagnose_use_after_transfer {
                        place_name = place.name
                        break
                    }
                }
            }
            if ownership_ir_event_requires_live_value(event.kind) &&
               event.place >= 0 && event.place < len(facts) &&
               !facts[event.place].must_live && place_name != "" {
                append(&plan.diagnostics, Ownership_IR_Diagnostic_Fact{
                    kind = .Use_After_Transfer,
                    certainty = .Conservative if facts[event.place].may_live else .Definite,
                    subject = strings.clone(place_name),
                    span = event.span,
                })
            }
            if event.kind == .Discard &&
               event.place >= 0 && event.place < len(facts) &&
               facts[event.place].may_live &&
               diagnostic_place != nil &&
               diagnostic_place.diagnose_discarded_result {
                append(&plan.diagnostics, Ownership_IR_Diagnostic_Fact{
                    kind = .Discarded_Result,
                    certainty = .Definite,
                    supports_scoped_cleanup =
                        diagnostic_place.discard_supports_scoped_cleanup,
                    subject = strings.clone(diagnostic_place.name),
                    span = event.span,
                })
            }
            if event.kind == .Reassign &&
               event.place >= 0 && event.place < len(facts) &&
               facts[event.place].may_live && place_name != "" &&
               (diagnostic_place == nil ||
                diagnostic_place.automatic_cleanup != .Managed) {
                append(&plan.diagnostics, Ownership_IR_Diagnostic_Fact{
                    kind = .Overwrite_Before_Cleanup,
                    certainty = .Definite if facts[event.place].must_live else .Conservative,
                    subject = strings.clone(place_name),
                    span = event.span,
                })
            }
            ownership_ir_apply_event(
                event,
                &facts,
                &valid,
                true,
            )
        }
        delete(facts)
    }
}

ownership_ir_cleanup_plan_has_action :: proc(
    plan: Ownership_IR_Cleanup_Plan,
    place, block: int,
) -> bool {
    for action in plan.actions {
        if action.place == place && action.block == block {
            return true
        }
    }
    return false
}

ownership_ir_cleanup_boundary_events_are_valid :: proc(
    block: Ownership_IR_Block,
) -> bool {
    for event in block.events {
        if event.kind != .Borrow_Owner_Exit {
            return false
        }
    }
    return true
}

ownership_ir_build_cleanup_plan :: proc(
    result: Ownership_IR_Shadow_Proc,
    analysis: Ownership_IR_Analysis,
) -> Ownership_IR_Cleanup_Plan {
    plan := Ownership_IR_Cleanup_Plan{
        valid = analysis.valid && analysis.converged,
    }
    for diagnostic in result.diagnostic_candidates {
        append(&plan.diagnostics, Ownership_IR_Diagnostic_Fact{
            kind = diagnostic.kind,
            reason = diagnostic.reason,
            certainty = diagnostic.certainty,
            supports_scoped_cleanup =
                diagnostic.supports_scoped_cleanup,
            subject = strings.clone(diagnostic.subject),
            span = diagnostic.span,
        })
    }
    if !plan.valid {
        ownership_ir_append_cleanup_diagnostics(result, &plan)
        return plan
    }
    for place in result.places {
        if place.cleanup_head == "" && !place.diagnose_unreleased {
            continue
        }
        if place.place < 0 ||
           place.place >= result.graph.place_count ||
           len(place.scope_exits) == 0 {
            plan.valid = false
            continue
        }
        for scope_exit in place.scope_exits {
            if scope_exit.block < 0 ||
               scope_exit.block >= len(analysis.blocks) ||
               scope_exit.block >= len(result.graph.blocks) ||
               !ownership_ir_cleanup_boundary_events_are_valid(
                   result.graph.blocks[scope_exit.block],
               ) ||
               ownership_ir_cleanup_plan_has_action(
                   plan,
                   place.place,
                   scope_exit.block,
               ) {
                plan.valid = false
                continue
            }
            reachable := analysis.blocks[scope_exit.block].reachable
            need := Ownership_IR_Cleanup_Need.None
            if reachable {
                need = ownership_ir_cleanup_need(
                    analysis.blocks[scope_exit.block].entry[place.place],
                )
            }
            append(&plan.actions, Ownership_IR_Cleanup_Action{
                place = place.place,
                block = scope_exit.block,
                exit_kind = scope_exit.kind,
                exit_source = scope_exit.source,
                need = need,
                reachable = reachable,
                references_place =
                    scope_exit.kind == .Return &&
                    result_form_references_name(
                        scope_exit.source_form,
                        place.name,
                    ),
                span = scope_exit.span,
            })
        }
    }
    ownership_ir_append_cleanup_diagnostics(result, &plan)
    return plan
}

ownership_ir_cleanup_plan_need :: proc(
    plan: Ownership_IR_Cleanup_Plan,
    place: int,
) -> Ownership_IR_Cleanup_Need {
    found := false
    any_live := false
    all_live := true
    for action in plan.actions {
        if action.place != place || !action.reachable {
            continue
        }
        found = true
        any_live = any_live || action.need != .None
        all_live = all_live && action.need == .Always
    }
    if !found || !any_live {
        return .None
    }
    return .Always if all_live else .Conditional
}

// A single lexical defer represents every scope exit exactly when all
// reachable exit actions agree. Mixed actions require explicit edge lowering.
ownership_ir_cleanup_plan_placement :: proc(
    plan: Ownership_IR_Cleanup_Plan,
    place: int,
) -> (Ownership_IR_Cleanup_Placement, Ownership_IR_Cleanup_Need) {
    if !plan.valid {
        return .None, .None
    }
    found := false
    uniform_need := Ownership_IR_Cleanup_Need.None
    for action in plan.actions {
        if action.place != place || !action.reachable {
            continue
        }
        if !found {
            found = true
            uniform_need = action.need
            continue
        }
        if action.need != uniform_need {
            return .Per_Exit, ownership_ir_cleanup_plan_need(plan, place)
        }
    }
    if !found || uniform_need == .None {
        return .None, .None
    }
    return .Scope_Defer, uniform_need
}

ownership_ir_place_has_manual_or_transfer_event :: proc(
    result: Ownership_IR_Shadow_Proc,
    place: int,
) -> bool {
    for block in result.graph.blocks {
        for event in block.events {
            if event.place != place {
                continue
            }
            #partial switch event.kind {
            case .Destroy, .Schedule_Destroy, .Transfer, .Return, .Move,
                 .Store, .Discard:
                return true
            case:
            }
        }
    }
    return false
}

ownership_ir_scope_cleanup_candidate :: proc(
    result: Ownership_IR_Shadow_Proc,
    plan: Ownership_IR_Cleanup_Plan,
    place: Ownership_IR_Shadow_Place,
) -> bool {
    placement, need := ownership_ir_cleanup_plan_placement(plan, place.place)
    if !plan.valid ||
       !place.direct_imported_contract ||
       place.legacy_cleanup == .None ||
       ownership_ir_place_has_manual_or_transfer_event(result, place.place) ||
       placement != .Scope_Defer ||
       need != place.legacy_cleanup {
        return false
    }
    return true
}

ownership_ir_place_activation_is_supported :: proc(
    place: Ownership_IR_Shadow_Place,
) -> bool {
    #partial switch place.activation {
    case .Always:
        return place.activation_index < 0
    case .Sibling_Nil, .Sibling_True:
        return place.activation_index >= 0
    }
    return false
}

ownership_ir_place_acquire_need :: proc(
    place: Ownership_IR_Shadow_Place,
) -> Ownership_IR_Cleanup_Need {
    return .Always if place.activation == .Always else .Conditional
}

ownership_ir_per_exit_action_is_supported :: proc(
    result: Ownership_IR_Shadow_Proc,
    action: Ownership_IR_Cleanup_Action,
) -> bool {
    if action.span.end <= action.span.start {
        return false
    }
    #partial switch action.exit_kind {
    case .Break, .Continue:
        return action.exit_source == .Explicit
    case .Return:
        // A cleanup edge may not compute from the value it destroys.
        // Implicit tail returns are limited to one result so their value can
        // be materialized without decomposing an Odin tuple.
        return action.exit_source != .Synthetic &&
               (action.exit_source != .Tail || result.return_count == 1) &&
               (action.need == .None || !action.references_place)
    case .Fallthrough:
        return action.exit_source == .Synthetic
    }
    return false
}

ownership_ir_per_exit_candidate :: proc(
    result: Ownership_IR_Shadow_Proc,
    plan: Ownership_IR_Cleanup_Plan,
    place: Ownership_IR_Shadow_Place,
) -> bool {
    placement, _ := ownership_ir_cleanup_plan_placement(plan, place.place)
    if !plan.valid ||
       !place.direct_imported_contract ||
       place.cleanup_head == "" ||
       place.legacy_cleanup != .None ||
       placement != .Per_Exit {
        return false
    }
    for block in result.graph.blocks {
        for event in block.events {
            if event.place != place.place {
                continue
            }
            // Owned-argument and managed-assignment lowering clear the active
            // owner flag for Transfer and Store. Move has no production
            // emission contract yet and stays conservative.
            #partial switch event.kind {
            case .Schedule_Destroy, .Move:
                return false
            case:
            }
        }
    }
    has_cleanup := false
    has_skip := false
    for action, action_index in plan.actions {
        if action.place != place.place || !action.reachable {
            continue
        }
        if !ownership_ir_per_exit_action_is_supported(
            result,
            action,
        ) {
            return false
        }
        for previous in plan.actions[:action_index] {
            if previous.place == place.place &&
               previous.reachable &&
               previous.exit_kind == action.exit_kind &&
               previous.span == action.span &&
               previous.need != action.need {
                return false
            }
        }
        #partial switch action.need {
        case .Always, .Conditional:
            if action.need == .Conditional &&
               !ownership_ir_place_activation_is_supported(place) {
                return false
            }
            has_cleanup = true
        case .None:
            has_skip = true
        }
    }
    return has_cleanup && has_skip
}

ownership_ir_plan_tracks_stored_owner :: proc(
    result: Ownership_IR_Shadow_Proc,
    plan: Ownership_IR_Cleanup_Plan,
    source_place: int,
) -> bool {
    if !plan.valid || source_place < 0 {
        return false
    }
    for block in result.graph.blocks {
        for event in block.events {
            if event.kind != .Store || event.place != source_place ||
               event.target < 0 {
                continue
            }
            target_place: ^Ownership_IR_Shadow_Place
            for &place in result.places {
                if place.place == event.target {
                    target_place = &place
                    break
                }
            }
            if target_place == nil ||
               target_place.aggregate_root == "" ||
               (target_place.aggregate_cleanup_unsupported &&
                !target_place.aggregate_return_transfers_owner) {
                continue
            }
            placement, need := ownership_ir_cleanup_plan_placement(
                plan,
                target_place.place,
            )
            if placement == .Scope_Defer && need != .None {
                return true
            }
            for target_block in result.graph.blocks {
                for target_event in target_block.events {
                    if target_event.place != target_place.place {
                        continue
                    }
                    #partial switch target_event.kind {
                    case .Destroy, .Schedule_Destroy, .Transfer, .Return, .Store:
                        return true
                    case:
                    }
                }
            }
        }
    }
    return false
}

ownership_ir_automatic_cleanup_covers_place :: proc(
    result: Ownership_IR_Shadow_Proc,
    place: Ownership_IR_Shadow_Place,
) -> bool {
    if place.automatic_cleanup == .None {
        return false
    }
    for block in result.graph.blocks {
        for event in block.events {
            if event.place != place.place {
                continue
            }
            #partial switch place.automatic_cleanup {
            case .Managed:
                // Managed owner flags remain active across assignments and
                // become false on transfers. An explicit cleanup suppresses
                // the generated owner-flag defer.
                if event.kind == .Destroy ||
                   event.kind == .Schedule_Destroy {
                    return false
                }
            case .Native:
                // Native owner flags are cleared by cleanup and transfer
                // events, so they safely cover the remaining paths. Reassign
                // replaces storage before that contract can protect the old
                // allocation and therefore disables automatic cleanup.
                if event.kind == .Reassign {
                    return false
                }
            case .None:
                return false
            }
        }
    }
    return true
}

ownership_ir_append_unreleased_diagnostics :: proc(
    result: Ownership_IR_Shadow_Proc,
    plan: ^Ownership_IR_Cleanup_Plan,
) {
    if plan == nil || !plan.valid {
        return
    }
    for place in result.places {
        if !place.diagnose_unreleased ||
           ownership_ir_automatic_cleanup_covers_place(result, place) {
            continue
        }
        found_exit := false
        any_live := false
        definitely_live_on_every_exit := true
        for action in plan.actions {
            if action.place != place.place || !action.reachable {
                continue
            }
            found_exit = true
            any_live = any_live || action.need != .None
            definitely_live_on_every_exit =
                definitely_live_on_every_exit && action.need == .Always
        }
        if !found_exit || !any_live {
            continue
        }
        append(&plan.diagnostics, Ownership_IR_Diagnostic_Fact{
            kind = .Unreleased_Local,
            certainty = .Definite if definitely_live_on_every_exit else .Conservative,
            subject = strings.clone(place.name),
            span = place.span,
        })
    }
}

ownership_ir_append_cleanup_diagnostics :: proc(
    result: Ownership_IR_Shadow_Proc,
    plan: ^Ownership_IR_Cleanup_Plan,
) {
    if plan == nil {
        return
    }
    ownership_ir_append_unreleased_diagnostics(result, plan)
    for place in result.places {
        if place.cleanup_skip_reason == .None ||
           ownership_ir_per_exit_candidate(result, plan^, place) ||
           ownership_ir_plan_tracks_stored_owner(
               result,
               plan^,
               place.place,
           ) {
            continue
        }
        append(&plan.diagnostics, Ownership_IR_Diagnostic_Fact{
            kind = .Automatic_Cleanup_Skipped,
            reason = place.cleanup_skip_reason,
            subject = strings.clone(place.name),
            span = place.span,
        })
    }
}

ownership_ir_current_plan_authorizes_scope_cleanup :: proc(
    e: ^Emitter,
    binding: Binding,
    name: string,
    expected: Ownership_IR_Cleanup_Need,
) -> bool {
    if e == nil ||
       e.current_ownership_shadow == nil ||
       e.current_ownership_plan == nil ||
       !e.current_ownership_plan.valid ||
       binding.deferred_delete ||
       binding.err_deferred_delete ||
       binding.defer_with_cleanup {
        return false
    }
    for place in e.current_ownership_shadow.places {
        if place.name != name ||
           place.span != binding.target_span ||
           place.legacy_cleanup != expected {
            continue
        }
        return ownership_ir_scope_cleanup_candidate(
            e.current_ownership_shadow^,
            e.current_ownership_plan^,
            place,
        )
    }
    return false
}

ownership_ir_current_plan_per_exit_place :: proc(
    e: ^Emitter,
    binding: Binding,
    name: string,
    expected: Ownership_IR_Cleanup_Need,
) -> (int, bool) {
    if e == nil ||
       e.current_ownership_shadow == nil ||
       e.current_ownership_plan == nil ||
       !e.current_ownership_plan.valid ||
       (expected != .Always && expected != .Conditional) ||
       binding.deferred_delete ||
       binding.err_deferred_delete ||
       binding.defer_with_cleanup {
        return -1, false
    }
    for place in e.current_ownership_shadow.places {
        if place.name != name ||
           place.span != binding.target_span ||
           ownership_ir_place_acquire_need(place) != expected ||
           !ownership_ir_place_activation_is_supported(place) ||
           (expected == .Conditional &&
            (place.activation_index < 0 ||
             place.activation_index >= len(binding.pattern) ||
             binding.pattern[place.activation_index] == "")) {
            continue
        }
        if ownership_ir_per_exit_candidate(
            e.current_ownership_shadow^,
            e.current_ownership_plan^,
            place,
        ) {
            return place.place, true
        }
    }
    return -1, false
}

ownership_ir_activate_per_exit_place :: proc(
    e: ^Emitter,
    binding: Binding,
    lifecycle: Result_Lifecycle,
    place: int,
) -> bool {
    if e == nil || e.current_ownership_shadow == nil {
        return false
    }
    matching_place := false
    for shadow_place in e.current_ownership_shadow.places {
        if shadow_place.place != place {
            continue
        }
        if shadow_place.activation != lifecycle.condition ||
           shadow_place.activation_index != lifecycle.condition_index {
            return false
        }
        matching_place = true
        break
    }
    if !matching_place {
        return false
    }
    active := Ownership_IR_Active_Place{place = place}
    if ownership_ir_active_place_needs_owner_flag(e, place) {
        condition := "true"
        if lifecycle.condition != .Always {
            condition_text, ok_condition := result_lifecycle_activation_text(
                lifecycle,
                binding.pattern[:],
            )
            if !ok_condition {
                return false
            }
            defer delete(condition_text)
            condition = condition_text
        }
        active.owner_flag = managed_owner_flag_name(e)
        emit_line(
            e,
            fmt.tprintf("%s := %s", active.owner_flag, condition),
        )
    }
    append(&e.ownership_active_per_exit_places, active)
    return true
}

ownership_ir_activate_bound_aggregate_places :: proc(
    e: ^Emitter,
    binding: Binding,
) {
    if e == nil || e.current_ownership_shadow == nil ||
       e.current_ownership_plan == nil ||
       !e.current_ownership_plan.valid || binding.name == "" ||
       binding.is_destructure || binding.is_result_binding ||
       binding.deferred_delete || binding.err_deferred_delete ||
       binding.defer_with_cleanup {
        return
    }
    for place in e.current_ownership_shadow.places {
        if place.aggregate_root != binding.name ||
           place.span != binding.target_span || place.ty == "" ||
           place.aggregate_cleanup_unsupported {
            continue
        }
        placement, need := ownership_ir_cleanup_plan_placement(
            e.current_ownership_plan^,
            place.place,
        )
        if placement != .Scope_Defer || need == .None {
            continue
        }
        if need == .Always {
            emit_line_mapped(
                e,
                fmt.tprintf(
                    "defer %s",
                    ownership_destroy_value_text(e, place.ty, place.name),
                ),
                binding.target_span,
            )
        } else {
            owner_flag := managed_owner_flag_name(e)
            emit_line_mapped(
                e,
                fmt.tprintf("%s := true", owner_flag),
                binding.target_span,
            )
            emit_line_mapped(
                e,
                fmt.tprintf(
                    "defer (proc(kvist_place: ^%s, kvist_owner: ^bool) {{ if kvist_owner^ {{ %s }} }})(%s, &%s)",
                    place.ty,
                    ownership_destroy_value_text(e, place.ty, "kvist_place^"),
                    address_of_expr_text(place.name),
                    owner_flag,
                ),
                binding.target_span,
            )
            append(
                &e.ownership_active_per_exit_places,
                Ownership_IR_Active_Place{
                    place = place.place,
                    owner_flag = owner_flag,
                },
            )
        }
        e.ownership_plan_adoptions += 1
    }
}

ownership_ir_current_plan_tracks_stored_owner :: proc(
    e: ^Emitter,
    binding: Binding,
    name: string,
) -> bool {
    if e == nil || e.current_ownership_shadow == nil ||
       e.current_ownership_plan == nil ||
       !e.current_ownership_plan.valid || name == "" {
        return false
    }
    source_place := -1
    for place in e.current_ownership_shadow.places {
        if place.name == name && place.span == binding.target_span {
            source_place = place.place
            break
        }
    }
    if source_place < 0 {
        return false
    }
    return ownership_ir_plan_tracks_stored_owner(
        e.current_ownership_shadow^,
        e.current_ownership_plan^,
        source_place,
    )
}

ownership_ir_per_exit_place_is_active :: proc(e: ^Emitter, place: int) -> bool {
    for active in e.ownership_active_per_exit_places {
        if active.place == place {
            return true
        }
    }
    return false
}

ownership_ir_active_place :: proc(
    e: ^Emitter,
    place: int,
) -> (Ownership_IR_Active_Place, bool) {
    for active in e.ownership_active_per_exit_places {
        if active.place == place {
            return active, true
        }
    }
    return {}, false
}

ownership_ir_current_transient_event :: proc(
    e: ^Emitter,
    form: CST_Form,
) -> (
    Ownership_IR_Event_Kind,
    Ownership_IR_Automatic_Cleanup,
    bool,
) {
    if e == nil || e.current_ownership_shadow == nil ||
       e.current_ownership_plan == nil ||
       !e.current_ownership_plan.valid {
        return .Call, .None, false
    }
    subject := owned_warning_subject(form)
    for place in e.current_ownership_shadow.places {
        if !place.transient || place.span != form.span ||
           place.name != subject {
            continue
        }
        for block in e.current_ownership_shadow.graph.blocks {
            for event in block.events {
                if event.place != place.place || event.span != form.span {
                    continue
                }
                if event.kind == .Destroy || event.kind == .Discard {
                    return event.kind, place.automatic_cleanup, true
                }
            }
        }
    }
    return .Call, .None, false
}

ownership_ir_current_binding_cleanup :: proc(
    e: ^Emitter,
    binding: Binding,
    automatic_cleanup: Ownership_IR_Automatic_Cleanup,
) -> (
    install: bool,
    track_owner: bool,
    tracked: bool,
) {
    if e == nil || e.current_ownership_shadow == nil ||
       e.current_ownership_plan == nil ||
       !e.current_ownership_plan.valid ||
       automatic_cleanup == .None ||
       binding.name == "" || binding.is_destructure ||
       binding.is_result_binding {
        return false, false, false
    }
    for place in e.current_ownership_shadow.places {
        if place.transient || place.name != binding.name ||
           place.span != binding.target_span ||
           place.automatic_cleanup != automatic_cleanup {
            continue
        }
        if !ownership_ir_automatic_cleanup_covers_place(
            e.current_ownership_shadow^,
            place,
        ) {
            return false, false, true
        }
        need := ownership_ir_cleanup_plan_need(
            e.current_ownership_plan^,
            place.place,
        )
        // Managed values still need an owner bit when every path transfers
        // them. The emitter uses it to move instead of retain, even though no
        // exit cleanup is necessary.
        track_owner = automatic_cleanup == .Managed
        return need != .None, track_owner, true
    }
    return false, false, false
}

ownership_ir_active_event_place :: proc(
    e: ^Emitter,
    name: string,
    span: Span,
    kind: Ownership_IR_Event_Kind,
) -> (int, bool) {
    if e == nil || e.current_ownership_shadow == nil {
        return -1, false
    }
    for place in e.current_ownership_shadow.places {
        if place.name == name {
            for block in e.current_ownership_shadow.graph.blocks {
                for event in block.events {
                    if event.place == place.place &&
                       event.kind == kind &&
                       event.span == span {
                        return place.place, true
                    }
                }
            }
        }
    }
    return -1, false
}

ownership_ir_active_event_owner_flag :: proc(
    e: ^Emitter,
    name: string,
    span: Span,
    kind: Ownership_IR_Event_Kind,
) -> (string, bool) {
    event_place, has_event := ownership_ir_active_event_place(
        e,
        name,
        span,
        kind,
    )
    if !has_event {
        return "", false
    }
    for active_index := len(e.ownership_active_per_exit_places)-1;
        active_index >= 0;
        active_index -= 1 {
        active := e.ownership_active_per_exit_places[active_index]
        if active.place == event_place && active.owner_flag != "" {
            return active.owner_flag, true
        }
    }
    return "", false
}

ownership_ir_active_place_needs_owner_flag :: proc(
    e: ^Emitter,
    place: int,
) -> bool {
    if e == nil || e.current_ownership_plan == nil {
        return false
    }
    for action in e.current_ownership_plan.actions {
        if action.place == place &&
           action.reachable &&
           action.need == .Conditional {
            return true
        }
    }
    return false
}

ownership_ir_emit_active_destroy_updates :: proc(
    e: ^Emitter,
    form: CST_Form,
) {
    if e == nil ||
       e.current_ownership_shadow == nil ||
       form.kind != .List ||
       len(form.items) < 2 ||
       form.items[0].kind != .Symbol {
        return
    }
    cleanup_head := map_name(form.items[0].text)
    defer delete(cleanup_head)
    for item in form.items[1:] {
        if item.kind != .Symbol {
            continue
        }
        name := map_name(item.text)
        for place in e.current_ownership_shadow.places {
            if place.name != name || place.cleanup_head != cleanup_head {
                continue
            }
            active, found := ownership_ir_active_place(e, place.place)
            if found && active.owner_flag != "" {
                emit_line_mapped(
                    e,
                    fmt.tprintf("%s = false", active.owner_flag),
                    item.span,
                )
            }
            break
        }
        delete(name)
    }
}

ownership_ir_active_edge_has_cleanup :: proc(
    e: ^Emitter,
    span: Span,
    kind: Ownership_IR_Exit_Kind,
) -> bool {
    if e == nil ||
       e.current_ownership_shadow == nil ||
       e.current_ownership_plan == nil {
        return false
    }
    for place in e.current_ownership_shadow.places {
        if !ownership_ir_per_exit_place_is_active(e, place.place) ||
           !ownership_ir_per_exit_candidate(
               e.current_ownership_shadow^,
               e.current_ownership_plan^,
               place,
           ) {
            continue
        }
        for action in e.current_ownership_plan.actions {
            if action.place == place.place &&
               action.reachable &&
               action.exit_kind == kind &&
               action.span == span &&
               action.need != .None {
                return true
            }
        }
    }
    return false
}

ownership_ir_emit_active_edge_cleanups :: proc(
    e: ^Emitter,
    span: Span,
    kind: Ownership_IR_Exit_Kind,
) {
    if e == nil ||
       e.current_ownership_shadow == nil ||
       e.current_ownership_plan == nil {
        return
    }
    for place_index := len(e.current_ownership_shadow.places)-1;
        place_index >= 0;
        place_index -= 1 {
        place := e.current_ownership_shadow.places[place_index]
        if !ownership_ir_per_exit_place_is_active(e, place.place) ||
           !ownership_ir_per_exit_candidate(
               e.current_ownership_shadow^,
               e.current_ownership_plan^,
               place,
           ) {
            continue
        }
        for action in e.current_ownership_plan.actions {
            if action.place != place.place ||
               !action.reachable ||
               action.exit_kind != kind ||
               action.span != span ||
               action.need == .None {
                continue
            }
            cleanup := fmt.tprintf("%s(%s)", place.cleanup_head, place.name)
            if action.need == .Conditional {
                active, has_active := ownership_ir_active_place(e, place.place)
                if !has_active || active.owner_flag == "" {
                    continue
                }
                emit_line_mapped(
                    e,
                    fmt.tprintf("if %s {{", active.owner_flag),
                    span,
                )
                e.indent += 1
                emit_line_mapped(e, cleanup, span)
                e.indent -= 1
                emit_line_mapped(e, "}", span)
            } else {
                emit_line_mapped(e, cleanup, span)
            }
            break
        }
    }
}

ownership_ir_cleanup_need_text :: proc(need: Ownership_IR_Cleanup_Need) -> string {
    #partial switch need {
    case .None:
        return "none"
    case .Always:
        return "always"
    case .Conditional:
        return "conditional"
    }
    return "none"
}

ownership_ir_exit_kind_text :: proc(kind: Ownership_IR_Exit_Kind) -> string {
    #partial switch kind {
    case .Fallthrough:
        return "fallthrough"
    case .Return:
        return "return"
    case .Break:
        return "break"
    case .Continue:
        return "continue"
    }
    return "fallthrough"
}

ownership_ir_cleanup_placement_text :: proc(
    placement: Ownership_IR_Cleanup_Placement,
) -> string {
    #partial switch placement {
    case .None:
        return "none"
    case .Scope_Defer:
        return "scope-defer"
    case .Per_Exit:
        return "per-exit"
    }
    return "none"
}

ownership_ir_cleanup_plan_count :: proc(
    plan: Ownership_IR_Cleanup_Plan,
    place: int,
    need: Ownership_IR_Cleanup_Need,
) -> int {
    count := 0
    for action in plan.actions {
        if action.place == place && action.reachable && action.need == need {
            count += 1
        }
    }
    return count
}

ownership_ir_write_cleanup_boundaries :: proc(
    builder: ^strings.Builder,
    plan: Ownership_IR_Cleanup_Plan,
    place: int,
) {
    first := true
    for action in plan.actions {
        if action.place != place {
            continue
        }
        if !first {
            strings.write_byte(builder, ',')
        }
        first = false
        fmt.sbprintf(
            builder,
            "b%d/%s/%s%s",
            action.block,
            ownership_ir_exit_kind_text(action.exit_kind),
            ownership_ir_cleanup_need_text(action.need),
            "" if action.reachable else "/unreachable",
        )
    }
}

ownership_ir_event_count :: proc(
    graph: Ownership_IR_Proc,
    place: int,
    kind: Ownership_IR_Event_Kind,
) -> int {
    count := 0
    for block in graph.blocks {
        for event in block.events {
            if event.place == place && event.kind == kind {
                count += 1
            }
        }
    }
    return count
}

ownership_ir_run_shadow :: proc(e: ^Emitter) -> Ownership_IR_Shadow_Stats {
    stats := Ownership_IR_Shadow_Stats{}
    if e == nil {
        return stats
    }
    for &decl in e.decls {
        if decl.kind != .Proc {
            continue
        }
        stats.procedures += 1
        shadow := ownership_ir_lower_proc(e, &decl.proc_decl)
        analysis := ownership_ir_analyze(shadow.graph)
        plan := ownership_ir_build_cleanup_plan(shadow, analysis)
        if !plan.valid {
            stats.invalid += 1
        } else {
            for place in shadow.places {
                if !place.borrowed_provenance {
                    stats.places += 1
                }
            }
            stats.actions += len(plan.actions)
            for action in plan.actions {
                if !action.reachable {
                    continue
                }
                if action.need == .Always {
                    stats.always += 1
                } else if action.need == .Conditional {
                    stats.conditional += 1
                }
            }
            for place in shadow.places {
                if place.borrowed_provenance {
                    continue
                }
                engine_need := ownership_ir_cleanup_plan_need(
                    plan,
                    place.place,
                )
                if engine_need == place.legacy_cleanup {
                    stats.matches += 1
                } else {
                    stats.mismatches += 1
                }
            }
        }
        ownership_ir_cleanup_plan_delete(&plan)
        ownership_ir_analysis_delete(&analysis)
        ownership_ir_shadow_proc_delete(&shadow)
    }
    return stats
}

// This inspection helper deliberately accepts the post-reader core language
// subset used by shadow tests. Production compilation runs the same lowering
// after normal macro expansion.
ownership_ir_shadow_source :: proc(
    source: string,
) -> (output: string, err: Compile_Error, ok: bool) {
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
    program, err_program, ok_program := parse_program(forms[:])
    if !ok_program {
        return "", clone_compile_error(err_program, result_allocator), false
    }
    lowered, err_lowered, ok_lowered := lower_program(program)
    if !ok_lowered {
        return "", clone_compile_error(err_lowered, result_allocator), false
    }

    import_cache := Emitter_Import_Cache{}
    emitter_import_cache_init(&import_cache)
    defer emitter_import_cache_delete(&import_cache)
    emitter := Emitter{
        decls = lowered.decls[:],
        import_cache = &import_cache,
    }
    infer_proc_lifetime_facts(&emitter)

    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    for &decl in emitter.decls {
        if decl.kind != .Proc {
            continue
        }
        shadow := ownership_ir_lower_proc(&emitter, &decl.proc_decl)
        analysis := ownership_ir_analyze(shadow.graph)
        if !analysis.valid || !analysis.converged {
            ownership_ir_analysis_delete(&analysis)
            ownership_ir_shadow_proc_delete(&shadow)
            return "", Compile_Error{
                message = "internal ownership IR shadow analysis did not converge",
                span = decl.span,
            }, false
        }
        plan := ownership_ir_build_cleanup_plan(shadow, analysis)
        if !plan.valid {
            ownership_ir_cleanup_plan_delete(&plan)
            ownership_ir_analysis_delete(&analysis)
            ownership_ir_shadow_proc_delete(&shadow)
            return "", Compile_Error{
                message = "internal ownership IR cleanup plan is invalid",
                span = decl.span,
            }, false
        }
        for place in shadow.places {
            if place.borrowed_provenance {
                continue
            }
            engine_need := ownership_ir_cleanup_plan_need(
                plan,
                place.place,
            )
            placement, _ := ownership_ir_cleanup_plan_placement(
                plan,
                place.place,
            )
            fmt.sbprintf(
                &builder,
                "%s\t%s\tengine=%s\tlegacy=%s\tmatch=%t\tcleanup=%s\tscheduled=%d\ttransfers=%d\texits=%d\tplan-always=%d\tplan-conditional=%d\tplan-none=%d\tplacement=%s\tadoptable=%t\tboundaries=",
                decl.proc_decl.name,
                place.name,
                ownership_ir_cleanup_need_text(engine_need),
                ownership_ir_cleanup_need_text(place.legacy_cleanup),
                engine_need == place.legacy_cleanup,
                place.cleanup_head,
                ownership_ir_event_count(
                    shadow.graph,
                    place.place,
                    .Schedule_Destroy,
                ),
                ownership_ir_event_count(
                    shadow.graph,
                    place.place,
                    .Transfer,
                ),
                len(place.scope_exits),
                ownership_ir_cleanup_plan_count(plan, place.place, .Always),
                ownership_ir_cleanup_plan_count(plan, place.place, .Conditional),
                ownership_ir_cleanup_plan_count(plan, place.place, .None),
                ownership_ir_cleanup_placement_text(placement),
                ownership_ir_scope_cleanup_candidate(shadow, plan, place) ||
                    ownership_ir_per_exit_candidate(shadow, plan, place),
            )
            ownership_ir_write_cleanup_boundaries(
                &builder,
                plan,
                place.place,
            )
            strings.write_byte(&builder, '\n')
        }
        ownership_ir_cleanup_plan_delete(&plan)
        ownership_ir_analysis_delete(&analysis)
        ownership_ir_shadow_proc_delete(&shadow)
    }
    return strings.clone(strings.to_string(builder), result_allocator), {}, true
}
