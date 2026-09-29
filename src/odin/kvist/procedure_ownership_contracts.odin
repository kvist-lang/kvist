package kvist

// Procedure ownership contracts are structured compiler facts. Symbol output
// serializes them for tools, while human-readable lifetime output consumes the
// fields directly and diagnostics can share the same representation.
Procedure_Ownership_Contract :: struct {
    result_flow:             Ownership_Result_Flow,
    owned_result_fields:     []int,
    result_fields_uncertain: bool,
    consumed_parameters:     [dynamic]int,
}

procedure_result_ownership_contract :: proc(
    decl: ^Proc_Decl,
    e: ^Emitter = nil,
) -> Procedure_Ownership_Contract {
    contract := Procedure_Ownership_Contract{
        owned_result_fields = decl.owned_result_fields[:],
        result_fields_uncertain = decl.owned_result_fields_uncertain,
    }
    borrowed_result := decl.borrows_result ||
                       (decl.returns.kind == .Single &&
                       len(decl.body) > 0 &&
                       (borrowed_source_param_tracked(
                            decl.body[len(decl.body)-1],
                            decl.returns.single_ty,
                            decl.params[:],
                        ) ||
                        known_odin_call_lifetime(
                            decl.body[len(decl.body)-1],
                        ) == .Borrowed))
    owned_result := !borrowed_result &&
                    (decl.owns_result ||
                     proc_decl_infers_owned_result(e, decl) ||
                     (len(decl.body) > 0 &&
                      form_infers_known_foreign_lifetime(
                          decl.body[len(decl.body)-1],
                          .Owned,
                          e = e,
                      )))
    if borrowed_result {
        contract.result_flow = .Borrowed
    } else if owned_result {
        contract.result_flow = .Owned
    }
    return contract
}

procedure_ownership_contract :: proc(
    decl: ^Proc_Decl,
    e: ^Emitter = nil,
) -> Procedure_Ownership_Contract {
    contract := procedure_result_ownership_contract(decl, e)

    for param, idx in decl.params {
        if param.ownership == .Owned {
            append(&contract.consumed_parameters, idx)
            continue
        }
        explicit_consumption :=
            body_deletes_or_returns_name(e, decl.body[:], param.name, false)
        transferred_result :=
            !type_text_has_managed_lifecycle(e, param.ty) &&
            contract.result_flow == .Owned &&
            body_deletes_or_returns_name(e, decl.body[:], param.name, true)
        if explicit_consumption || transferred_result {
            append(&contract.consumed_parameters, idx)
        }
    }
    return contract
}

procedure_ownership_contract_delete :: proc(
    contract: ^Procedure_Ownership_Contract,
) {
    delete(contract.consumed_parameters)
    contract^ = {}
}

procedure_ownership_contract_has_facts :: proc(
    contract: ^Procedure_Ownership_Contract,
) -> bool {
    return contract.result_flow != .Unknown ||
           len(contract.owned_result_fields) > 0 ||
           contract.result_fields_uncertain ||
           len(contract.consumed_parameters) > 0
}

procedure_ownership_contract_consumes :: proc(
    contract: ^Procedure_Ownership_Contract,
    parameter_index: int,
) -> bool {
    for consumed_index in contract.consumed_parameters {
        if consumed_index == parameter_index {
            return true
        }
    }
    return false
}

procedure_ownership_contract_consumes_name :: proc(
    contract: ^Procedure_Ownership_Contract,
    decl: ^Proc_Decl,
    parameter_name: string,
) -> bool {
    for param, parameter_index in decl.params {
        if param.name == parameter_name {
            return procedure_ownership_contract_consumes(
                contract,
                parameter_index,
            )
        }
    }
    return false
}
