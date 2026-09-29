package kvist

import "core:fmt"
import "core:strings"

// Ownership contracts describe facts that cannot be recovered from an opaque
// call signature. Both the managed Data runtime and imported Odin resources
// use this registry; control-flow analysis must not grow API-specific rules.
Ownership_Call_Match_Kind :: enum {
    Runtime_Target,
    Runtime_Prefix,
    Imported_Member,
}

Ownership_Result_Flow :: enum {
    Unknown,
    Borrowed,
    Owned,
}

Ownership_Cleanup_Kind :: enum {
    None,
    Type_Default,
    Call,
}

Ownership_Activation :: enum {
    Always,
    Sibling_Nil,
    Sibling_True,
}

Ownership_Call_Contract :: struct {
    match_kind:       Ownership_Call_Match_Kind,
    target:           string,
    path:             string,
    member:           string,
    result_count:     int,
    result_index:     int,
    result_type:      string,
    result_flow:      Ownership_Result_Flow,
    cleanup_kind:     Ownership_Cleanup_Kind,
    cleanup_member:   string,
    activation:       Ownership_Activation,
    activation_index: int,
}

// Keep imported contracts exact. Runtime_Prefix is reserved for the
// compiler-owned Kvist runtime ABI, where the constructor family is itself a
// stable contract. A name that merely resembles an allocator or destructor is
// never sufficient evidence for an imported Odin call.
OWNERSHIP_CALL_CONTRACTS :: []Ownership_Call_Contract{
    {
        match_kind = .Runtime_Prefix,
        target = "kvist_data_make_",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_empty_map",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_freeze_items",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_freeze_map",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_freeze_unique_map",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_retain",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_assoc",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_update",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_dissoc",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_conj",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_disj",
        result_count = 1,
        result_index = 0,
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_string",
        result_count = 1,
        result_index = 0,
        result_flow = .Borrowed,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_symbol",
        result_count = 1,
        result_index = 0,
        result_flow = .Borrowed,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_keyword",
        result_count = 1,
        result_index = 0,
        result_flow = .Borrowed,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_text",
        result_count = 1,
        result_index = 0,
        result_flow = .Borrowed,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_tag",
        result_count = 1,
        result_index = 0,
        result_flow = .Borrowed,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_tagged_value",
        result_count = 1,
        result_index = 0,
        result_flow = .Borrowed,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_key_at",
        result_count = 1,
        result_index = 0,
        result_flow = .Borrowed,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_value_at",
        result_count = 1,
        result_index = 0,
        result_flow = .Borrowed,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_item_at",
        result_count = 1,
        result_index = 0,
        result_flow = .Borrowed,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Runtime_Target,
        target = "kvist_data_get",
        result_count = 1,
        result_index = 0,
        result_flow = .Borrowed,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Imported_Member,
        path = "core:os",
        member = "read_entire_file",
        result_count = 2,
        result_index = 0,
        result_type = "[]byte",
        result_flow = .Owned,
        cleanup_kind = .Type_Default,
        activation = .Always,
        activation_index = -1,
    },
    {
        match_kind = .Imported_Member,
        path = "core:os",
        member = "open",
        result_count = 2,
        result_index = 0,
        result_type = "^File",
        result_flow = .Owned,
        cleanup_kind = .Call,
        cleanup_member = "close",
        activation = .Sibling_Nil,
        activation_index = 1,
    },
    {
        match_kind = .Imported_Member,
        path = "core:os",
        member = "create",
        result_count = 2,
        result_index = 0,
        result_type = "^File",
        result_flow = .Owned,
        cleanup_kind = .Call,
        cleanup_member = "close",
        activation = .Sibling_Nil,
        activation_index = 1,
    },
    {
        match_kind = .Imported_Member,
        path = "core:os",
        member = "clone",
        result_count = 2,
        result_index = 0,
        result_type = "^File",
        result_flow = .Owned,
        cleanup_kind = .Call,
        cleanup_member = "close",
        activation = .Sibling_Nil,
        activation_index = 1,
    },
    {
        match_kind = .Imported_Member,
        path = "core:text/regex",
        member = "create",
        result_count = 2,
        result_index = 0,
        result_type = "Regular_Expression",
        result_flow = .Owned,
        cleanup_kind = .Call,
        cleanup_member = "destroy",
        activation = .Sibling_Nil,
        activation_index = 1,
    },
    {
        match_kind = .Imported_Member,
        path = "core:text/regex",
        member = "match_and_allocate_capture",
        result_count = 2,
        result_index = 0,
        result_type = "Capture",
        result_flow = .Owned,
        cleanup_kind = .Call,
        cleanup_member = "destroy",
        activation = .Sibling_True,
        activation_index = 1,
    },
}

ownership_runtime_contract :: proc(target: string) -> (Ownership_Call_Contract, bool) {
    for contract in OWNERSHIP_CALL_CONTRACTS {
        if contract.match_kind == .Runtime_Target && contract.target == target {
            return contract, true
        }
    }
    for contract in OWNERSHIP_CALL_CONTRACTS {
        if contract.match_kind == .Runtime_Prefix && strings.has_prefix(target, contract.target) {
            return contract, true
        }
    }
    return {}, false
}

ownership_imported_result_contract :: proc(
    e: ^Emitter,
    head: string,
    result_index, result_count: int,
) -> (Ownership_Call_Contract, bool) {
    for contract in OWNERSHIP_CALL_CONTRACTS {
        if contract.match_kind == .Imported_Member &&
           contract.result_count == result_count &&
           contract.result_index == result_index &&
           imported_interop_call_matches(e, head, contract.path, contract.member) {
            return contract, true
        }
    }
    return {}, false
}

ownership_imported_call_result_count :: proc(e: ^Emitter, head: string) -> (int, bool) {
    for contract in OWNERSHIP_CALL_CONTRACTS {
        if contract.match_kind == .Imported_Member &&
           imported_interop_call_matches(e, head, contract.path, contract.member) {
            return contract.result_count, true
        }
    }
    return 0, false
}

ownership_contract_identity_matches :: proc(left, right: Ownership_Call_Contract) -> bool {
    if left.match_kind != right.match_kind ||
       left.result_count != right.result_count ||
       left.result_index != right.result_index {
        return false
    }
    #partial switch left.match_kind {
    case .Runtime_Target, .Runtime_Prefix:
        return left.target == right.target
    case .Imported_Member:
        return left.path == right.path && left.member == right.member
    }
    return false
}

ownership_contracts_validate :: proc() -> (message: string, ok: bool) {
    contracts := OWNERSHIP_CALL_CONTRACTS
    for contract, index in contracts {
        if contract.result_count <= 0 ||
           contract.result_index < 0 ||
           contract.result_index >= contract.result_count {
            return fmt.tprintf("ownership contract %d has an invalid result index", index), false
        }
        if contract.result_flow == .Unknown {
            return fmt.tprintf("ownership contract %d has unknown result flow", index), false
        }
        #partial switch contract.match_kind {
        case .Runtime_Target, .Runtime_Prefix:
            if contract.target == "" || contract.path != "" || contract.member != "" {
                return fmt.tprintf("ownership contract %d has an invalid runtime target", index), false
            }
        case .Imported_Member:
            if contract.path == "" || contract.member == "" || contract.target != "" {
                return fmt.tprintf("ownership contract %d has an invalid imported member", index), false
            }
        }
        if contract.result_flow == .Borrowed && contract.cleanup_kind != .None {
            return fmt.tprintf("borrowed ownership contract %d has cleanup", index), false
        }
        if contract.result_flow == .Owned && contract.cleanup_kind == .None {
            return fmt.tprintf("owned ownership contract %d has no cleanup policy", index), false
        }
        if contract.match_kind == .Imported_Member &&
           contract.result_flow == .Owned &&
           contract.result_type == "" {
            return fmt.tprintf("owned imported contract %d has no result type", index), false
        }
        if contract.cleanup_kind == .Call && contract.cleanup_member == "" {
            return fmt.tprintf("ownership contract %d has no cleanup call", index), false
        }
        if contract.cleanup_kind != .Call && contract.cleanup_member != "" {
            return fmt.tprintf("ownership contract %d has an unused cleanup call", index), false
        }
        if contract.activation == .Always {
            if contract.activation_index != -1 {
                return fmt.tprintf("ownership contract %d has an unexpected activation index", index), false
            }
        } else if contract.activation_index < 0 ||
                  contract.activation_index >= contract.result_count ||
                  contract.activation_index == contract.result_index {
            return fmt.tprintf("ownership contract %d has an invalid activation result", index), false
        }
        for previous in 0..<index {
            previous_contract := contracts[previous]
            if ownership_contract_identity_matches(contract, previous_contract) {
                return fmt.tprintf("ownership contract %d duplicates contract %d", index, previous), false
            }
            if contract.match_kind == .Imported_Member &&
               previous_contract.match_kind == .Imported_Member &&
               contract.path == previous_contract.path &&
               contract.member == previous_contract.member &&
               contract.result_count != previous_contract.result_count {
                return fmt.tprintf("ownership contract %d disagrees with contract %d about result count", index, previous), false
            }
        }
    }
    return "", true
}
