package kvist

// Ownership IR is deliberately independent of concrete resources and source
// syntax. Call contracts and lowering decide which semantic operations enter
// the graph; this layer tracks ownership and borrow facts over the common CFG.
//
// Acquire/Reassign start an ownership obligation. Copy preserves the source,
// while Move, Store, Transfer, Return, Discard, and Destroy end it at `place`.
// Schedule_Destroy records future scope cleanup without ending value liveness.
// Borrow events form a second lattice: Assign/Copy/Clear update provenance,
// Use/Escape/Delete are diagnostic observations, and Owner_Exit represents a
// cleanup boundary. Destroy also invalidates every borrow of the owner.
Ownership_IR_Exit_Kind :: enum {
    Fallthrough,
    Return,
    Break,
    Continue,
}

Ownership_IR_Exit_Source :: enum {
    Synthetic,
    Explicit,
    Tail,
}

Ownership_IR_Event_Kind :: enum {
    Acquire,
    Reassign,
    Borrow,
    Copy,
    Move,
    Store,
    Destroy,
    Schedule_Destroy,
    Transfer,
    Return,
    Discard,
    Call,
    Borrow_Assign,
    Borrow_Copy,
    Borrow_Clear,
    Borrow_Use,
    Borrow_Escape,
    Borrow_Delete,
    Borrow_Owner_Exit,
}

Ownership_IR_Event :: struct {
    kind:        Ownership_IR_Event_Kind,
    place:       int,
    target:      int,
    conditional: bool,
    span:        Span,
}

Ownership_IR_Block :: struct {
    events:     [dynamic]Ownership_IR_Event,
    successors: [dynamic]int,
}

Ownership_IR_Proc :: struct {
    place_count: int,
    entry:       int,
    blocks:      [dynamic]Ownership_IR_Block,
}

// may_live answers whether at least one incoming path has an uncovered
// ownership obligation; must_live answers whether every incoming path does.
// The scheduled flags remember a deferred cleanup separately from the current
// value, so a later reassignment remains covered by the same scope defer.
Ownership_IR_Live_Fact :: struct {
    may_live:               bool,
    must_live:              bool,
    may_cleanup_scheduled:  bool,
    must_cleanup_scheduled: bool,
}

Ownership_IR_Block_Facts :: struct {
    reachable: bool,
    entry:     [dynamic]Ownership_IR_Live_Fact,
    exit:      [dynamic]Ownership_IR_Live_Fact,
}

Ownership_IR_Analysis :: struct {
    blocks:    [dynamic]Ownership_IR_Block_Facts,
    valid:     bool,
    converged: bool,
}

// Borrowed-ness and owner provenance have slightly different joins. A value
// can be borrowed on every path while referring to different owners on those
// paths, so the row-level may/must fact is kept separately from the union of
// possible owner relations.
Ownership_IR_Borrow_Fact :: struct {
    may_borrowed:  bool,
    must_borrowed: bool,
}

Ownership_IR_Borrow_Invalid_Fact :: struct {
    may_invalid:  bool,
    must_invalid: bool,
}

Ownership_IR_Borrow_Block_Facts :: struct {
    reachable:            bool,
    entry_owners:         [dynamic]bool,
    exit_owners:          [dynamic]bool,
    entry_invalid_owners: [dynamic]bool,
    exit_invalid_owners:  [dynamic]bool,
    entry:                [dynamic]Ownership_IR_Borrow_Fact,
    exit:                 [dynamic]Ownership_IR_Borrow_Fact,
    entry_invalid:        [dynamic]Ownership_IR_Borrow_Invalid_Fact,
    exit_invalid:         [dynamic]Ownership_IR_Borrow_Invalid_Fact,
}

Ownership_IR_Borrow_Analysis :: struct {
    blocks:    [dynamic]Ownership_IR_Borrow_Block_Facts,
    valid:     bool,
    converged: bool,
}

Ownership_IR_Cleanup_Need :: enum {
    None,
    Always,
    Conditional,
}

Ownership_IR_Cleanup_Placement :: enum {
    None,
    Scope_Defer,
    Per_Exit,
}

Ownership_IR_Automatic_Cleanup :: enum {
    None,
    Managed,
    Native,
}

Ownership_IR_Diagnostic_Kind :: enum {
    Aggregate_Result_Fields_Uncertain,
    Aggregate_Field_Ownership_Uncertain,
    Explicit_Aggregate_Cleanup_Conditional,
    Automatic_Cleanup_Skipped,
    Use_After_Transfer,
    Overwrite_Before_Cleanup,
    Unreleased_Local,
    Discarded_Result,
    Borrowed_Escape,
    Borrowed_Use_After_Destroy,
    Borrowed_Delete_Result,
    Borrowed_Delete_Local,
}

Ownership_IR_Cleanup_Skip_Reason :: enum {
    None,
    Captured_By_Closure,
    Stored_Or_Mutable,
}

Ownership_IR_Diagnostic_Certainty :: enum {
    Definite,
    Conservative,
}

// Diagnostics are facts produced by ownership planning, not preformatted
// compiler messages. This keeps policy and presentation out of dataflow.
Ownership_IR_Diagnostic_Fact :: struct {
    kind:      Ownership_IR_Diagnostic_Kind,
    reason:    Ownership_IR_Cleanup_Skip_Reason,
    certainty: Ownership_IR_Diagnostic_Certainty,
    supports_scoped_cleanup: bool,
    subject:   string,
    span:      Span,
}

Ownership_IR_Cleanup_Action :: struct {
    place:            int,
    block:            int,
    exit_kind:        Ownership_IR_Exit_Kind,
    exit_source:      Ownership_IR_Exit_Source,
    need:             Ownership_IR_Cleanup_Need,
    reachable:        bool,
    references_place: bool,
    span:             Span,
}

Ownership_IR_Cleanup_Plan :: struct {
    actions:     [dynamic]Ownership_IR_Cleanup_Action,
    diagnostics: [dynamic]Ownership_IR_Diagnostic_Fact,
    valid:       bool,
}

ownership_ir_cleanup_plan_delete :: proc(plan: ^Ownership_IR_Cleanup_Plan) {
    delete(plan.actions)
    for &diagnostic in plan.diagnostics {
        delete(diagnostic.subject)
    }
    delete(plan.diagnostics)
    plan^ = {}
}

ownership_ir_add_block :: proc(graph: ^Ownership_IR_Proc) -> int {
    append(&graph.blocks, Ownership_IR_Block{})
    return len(graph.blocks) - 1
}

ownership_ir_add_event :: proc(
    graph: ^Ownership_IR_Proc,
    block: int,
    event: Ownership_IR_Event,
) -> bool {
    if block < 0 || block >= len(graph.blocks) {
        return false
    }
    append(&graph.blocks[block].events, event)
    return true
}

ownership_ir_add_successor :: proc(
    graph: ^Ownership_IR_Proc,
    block, successor: int,
) -> bool {
    if block < 0 || block >= len(graph.blocks) ||
       successor < 0 || successor >= len(graph.blocks) {
        return false
    }
    append(&graph.blocks[block].successors, successor)
    return true
}

ownership_ir_proc_delete :: proc(graph: ^Ownership_IR_Proc) {
    for &block in graph.blocks {
        delete(block.events)
        delete(block.successors)
    }
    delete(graph.blocks)
    graph^ = {}
}

ownership_ir_analysis_delete :: proc(analysis: ^Ownership_IR_Analysis) {
    for &block in analysis.blocks {
        delete(block.entry)
        delete(block.exit)
    }
    delete(analysis.blocks)
    analysis^ = {}
}

ownership_ir_borrow_analysis_delete :: proc(
    analysis: ^Ownership_IR_Borrow_Analysis,
) {
    for &block in analysis.blocks {
        delete(block.entry_owners)
        delete(block.exit_owners)
        delete(block.entry_invalid_owners)
        delete(block.exit_invalid_owners)
        delete(block.entry)
        delete(block.exit)
        delete(block.entry_invalid)
        delete(block.exit_invalid)
    }
    delete(analysis.blocks)
    analysis^ = {}
}

ownership_ir_facts_equal :: proc(
    left, right: []Ownership_IR_Live_Fact,
) -> bool {
    if len(left) != len(right) {
        return false
    }
    for fact, index in left {
        if fact != right[index] {
            return false
        }
    }
    return true
}

ownership_ir_copy_facts :: proc(
    target: ^[dynamic]Ownership_IR_Live_Fact,
    source: []Ownership_IR_Live_Fact,
) {
    resize(target, len(source))
    copy(target^[:], source)
}

ownership_ir_join_facts :: proc(
    target: ^[dynamic]Ownership_IR_Live_Fact,
    incoming: []Ownership_IR_Live_Fact,
) -> bool {
    changed := false
    for fact, index in incoming {
        joined := Ownership_IR_Live_Fact{
            may_live = target[index].may_live || fact.may_live,
            must_live = target[index].must_live && fact.must_live,
            may_cleanup_scheduled =
                target[index].may_cleanup_scheduled ||
                fact.may_cleanup_scheduled,
            must_cleanup_scheduled =
                target[index].must_cleanup_scheduled &&
                fact.must_cleanup_scheduled,
        }
        if joined != target[index] {
            target[index] = joined
            changed = true
        }
    }
    return changed
}

ownership_ir_event_place_valid :: proc(
    event: Ownership_IR_Event,
    place_count: int,
) -> bool {
    if event.kind == .Call {
        return true
    }
    if event.kind == .Borrow_Escape && event.place == -1 {
        return event.target >= 0 && event.target < place_count
    }
    if event.place < 0 || event.place >= place_count {
        return false
    }
    // Store target -1 represents ownership moved into storage outside the
    // tracked local-place graph.
    if event.kind == .Store && event.target == -1 {
        return true
    }
    return (event.kind != .Copy && event.kind != .Move && event.kind != .Store &&
            event.kind != .Borrow_Assign && event.kind != .Borrow_Copy &&
            event.kind != .Borrow_Owner_Exit) ||
           (event.target >= 0 && event.target < place_count)
}

ownership_ir_apply_event :: proc(
    event: Ownership_IR_Event,
    facts: ^[dynamic]Ownership_IR_Live_Fact,
    valid: ^bool,
    value_liveness := false,
) {
    if !ownership_ir_event_place_valid(event, len(facts^)) {
        valid^ = false
        return
    }
    #partial switch event.kind {
    case .Acquire, .Reassign:
        if value_liveness {
            facts[event.place].may_live = true
            // Conditional acquisition affects cleanup responsibility, not
            // whether the local may subsequently be referenced.
            facts[event.place].must_live = true
        } else {
            facts[event.place].may_live =
                !facts[event.place].must_cleanup_scheduled
            facts[event.place].must_live =
                !event.conditional &&
                !facts[event.place].may_cleanup_scheduled
        }
    case .Copy:
        if value_liveness {
            facts[event.target] = facts[event.place]
        } else {
            facts[event.target].may_live =
                facts[event.place].may_live &&
                !facts[event.target].must_cleanup_scheduled
            facts[event.target].must_live =
                facts[event.place].must_live &&
                !facts[event.target].may_cleanup_scheduled
        }
    case .Move:
        if value_liveness {
            facts[event.target] = facts[event.place]
            facts[event.place] = {}
        } else {
            facts[event.target].may_live =
                facts[event.place].may_live &&
                !facts[event.target].must_cleanup_scheduled
            facts[event.target].must_live =
                facts[event.place].must_live &&
                !facts[event.target].may_cleanup_scheduled
            facts[event.place].may_live = false
            facts[event.place].must_live = false
        }
    case .Store:
        if event.target >= 0 {
            if value_liveness {
                facts[event.target] = facts[event.place]
            } else {
                facts[event.target].may_live =
                    facts[event.place].may_live &&
                    !facts[event.target].must_cleanup_scheduled
                facts[event.target].must_live =
                    facts[event.place].must_live &&
                    !facts[event.target].may_cleanup_scheduled
            }
        }
        facts[event.place].may_live = false
        facts[event.place].must_live = false
    case .Schedule_Destroy:
        if value_liveness {
            // A defer schedules future destruction but leaves the value usable
            // until its scope actually exits.
        } else if event.conditional {
            facts[event.place].may_cleanup_scheduled = true
            facts[event.place].must_live = false
        } else {
            facts[event.place].may_cleanup_scheduled = true
            facts[event.place].must_cleanup_scheduled = true
            facts[event.place].may_live = false
            facts[event.place].must_live = false
        }
    case .Destroy, .Transfer, .Return, .Discard:
        facts[event.place].may_live = false
        facts[event.place].must_live = false
    case .Borrow, .Call, .Borrow_Assign, .Borrow_Copy, .Borrow_Clear,
         .Borrow_Use, .Borrow_Escape, .Borrow_Delete, .Borrow_Owner_Exit:
        // These operations do not change ownership. The verifier later uses
        // them to diagnose invalid use paths.
    }
}

ownership_ir_transfer_block :: proc(
    block: Ownership_IR_Block,
    entry: []Ownership_IR_Live_Fact,
    output: ^[dynamic]Ownership_IR_Live_Fact,
    valid: ^bool,
    value_liveness := false,
) {
    ownership_ir_copy_facts(output, entry)
    for event in block.events {
        ownership_ir_apply_event(event, output, valid, value_liveness)
    }
}

ownership_ir_analyze_mode :: proc(
    graph: Ownership_IR_Proc,
    value_liveness: bool,
) -> Ownership_IR_Analysis {
    analysis := Ownership_IR_Analysis{valid = true}
    if graph.place_count < 0 ||
       graph.entry < 0 ||
       graph.entry >= len(graph.blocks) {
        analysis.valid = false
        return analysis
    }
    resize(&analysis.blocks, len(graph.blocks))
    for &facts in analysis.blocks {
        resize(&facts.entry, graph.place_count)
        resize(&facts.exit, graph.place_count)
    }
    analysis.blocks[graph.entry].reachable = true

    iteration_limit := max(16, len(graph.blocks)*(graph.place_count+1)*4)
    for _ in 0..<iteration_limit {
        changed := false
        for block, block_index in graph.blocks {
            block_facts := &analysis.blocks[block_index]
            if !block_facts.reachable {
                continue
            }
            previous_exit := make(
                []Ownership_IR_Live_Fact,
                len(block_facts.exit),
                context.temp_allocator,
            )
            copy(previous_exit[:], block_facts.exit[:])
            ownership_ir_transfer_block(
                block,
                block_facts.entry[:],
                &block_facts.exit,
                &analysis.valid,
                value_liveness,
            )
            if !ownership_ir_facts_equal(previous_exit[:], block_facts.exit[:]) {
                changed = true
            }
            for successor in block.successors {
                if successor < 0 || successor >= len(graph.blocks) {
                    analysis.valid = false
                    continue
                }
                successor_facts := &analysis.blocks[successor]
                if !successor_facts.reachable {
                    successor_facts.reachable = true
                    ownership_ir_copy_facts(
                        &successor_facts.entry,
                        block_facts.exit[:],
                    )
                    changed = true
                } else if ownership_ir_join_facts(
                    &successor_facts.entry,
                    block_facts.exit[:],
                ) {
                    changed = true
                }
            }
        }
        if !changed {
            analysis.converged = true
            break
        }
    }
    return analysis
}

ownership_ir_analyze :: proc(graph: Ownership_IR_Proc) -> Ownership_IR_Analysis {
    return ownership_ir_analyze_mode(graph, false)
}

ownership_ir_analyze_value_liveness :: proc(
    graph: Ownership_IR_Proc,
) -> Ownership_IR_Analysis {
    return ownership_ir_analyze_mode(graph, true)
}

ownership_ir_borrow_row_clear :: proc(
    facts: ^[dynamic]bool,
    place_count, borrower: int,
) {
    if borrower < 0 || borrower >= place_count {
        return
    }
    start := borrower*place_count
    for index in 0..<place_count {
        facts[start+index] = false
    }
}

ownership_ir_apply_borrow_event :: proc(
    event: Ownership_IR_Event,
    owners: ^[dynamic]bool,
    facts: ^[dynamic]Ownership_IR_Borrow_Fact,
    invalid_owners: ^[dynamic]bool,
    invalid_facts: ^[dynamic]Ownership_IR_Borrow_Invalid_Fact,
    place_count: int,
    valid: ^bool,
) {
    if !ownership_ir_event_place_valid(event, place_count) {
        valid^ = false
        return
    }
    #partial switch event.kind {
    case .Borrow_Assign:
        ownership_ir_borrow_row_clear(owners, place_count, event.place)
        ownership_ir_borrow_row_clear(
            invalid_owners,
            place_count,
            event.place,
        )
        owners[event.place*place_count+event.target] = true
        facts[event.place] = {may_borrowed = true, must_borrowed = true}
        invalid_facts[event.place] = {}
    case .Borrow_Copy:
        if event.place == event.target {
            return
        }
        ownership_ir_borrow_row_clear(owners, place_count, event.place)
        ownership_ir_borrow_row_clear(
            invalid_owners,
            place_count,
            event.place,
        )
        target_start := event.place*place_count
        source_start := event.target*place_count
        for index in 0..<place_count {
            owners[target_start+index] = owners[source_start+index]
            invalid_owners[target_start+index] =
                invalid_owners[source_start+index]
        }
        facts[event.place] = facts[event.target]
        invalid_facts[event.place] = invalid_facts[event.target]
    case .Borrow_Clear:
        ownership_ir_borrow_row_clear(owners, place_count, event.place)
        ownership_ir_borrow_row_clear(
            invalid_owners,
            place_count,
            event.place,
        )
        facts[event.place] = {}
        invalid_facts[event.place] = {}
    case .Destroy:
        for borrower in 0..<place_count {
            relation := borrower*place_count+event.place
            if !owners[relation] {
                continue
            }
            owners[relation] = false
            invalid_owners[relation] = true
            invalid_facts[borrower].may_invalid = true
            has_valid_owner := false
            row_start := borrower*place_count
            for owner in 0..<place_count {
                if owners[row_start+owner] {
                    has_valid_owner = true
                    break
                }
            }
            if facts[borrower].must_borrowed && !has_valid_owner {
                invalid_facts[borrower].must_invalid = true
            }
        }
    case .Borrow_Use, .Borrow_Escape, .Borrow_Delete, .Borrow_Owner_Exit,
         .Acquire, .Reassign, .Borrow, .Copy, .Move, .Store,
         .Schedule_Destroy, .Transfer, .Return, .Discard, .Call:
    }
}

ownership_ir_analyze_borrows :: proc(
    graph: Ownership_IR_Proc,
) -> Ownership_IR_Borrow_Analysis {
    analysis := Ownership_IR_Borrow_Analysis{valid = true}
    if graph.place_count < 0 || graph.entry < 0 ||
       graph.entry >= len(graph.blocks) {
        analysis.valid = false
        return analysis
    }
    fact_count := graph.place_count*graph.place_count
    resize(&analysis.blocks, len(graph.blocks))
    for &facts in analysis.blocks {
        resize(&facts.entry_owners, fact_count)
        resize(&facts.exit_owners, fact_count)
        resize(&facts.entry_invalid_owners, fact_count)
        resize(&facts.exit_invalid_owners, fact_count)
        resize(&facts.entry, graph.place_count)
        resize(&facts.exit, graph.place_count)
        resize(&facts.entry_invalid, graph.place_count)
        resize(&facts.exit_invalid, graph.place_count)
    }
    analysis.blocks[graph.entry].reachable = true

    iteration_limit := max(16, len(graph.blocks)*(fact_count+1)*4)
    for _ in 0..<iteration_limit {
        changed := false
        for block, block_index in graph.blocks {
            block_facts := &analysis.blocks[block_index]
            if !block_facts.reachable {
                continue
            }
            copy(block_facts.exit_owners[:], block_facts.entry_owners[:])
            copy(
                block_facts.exit_invalid_owners[:],
                block_facts.entry_invalid_owners[:],
            )
            copy(block_facts.exit[:], block_facts.entry[:])
            copy(
                block_facts.exit_invalid[:],
                block_facts.entry_invalid[:],
            )
            for event in block.events {
                ownership_ir_apply_borrow_event(
                    event,
                    &block_facts.exit_owners,
                    &block_facts.exit,
                    &block_facts.exit_invalid_owners,
                    &block_facts.exit_invalid,
                    graph.place_count,
                    &analysis.valid,
                )
            }
            for successor in block.successors {
                if successor < 0 || successor >= len(graph.blocks) {
                    analysis.valid = false
                    continue
                }
                successor_facts := &analysis.blocks[successor]
                if !successor_facts.reachable {
                    successor_facts.reachable = true
                    copy(
                        successor_facts.entry_owners[:],
                        block_facts.exit_owners[:],
                    )
                    copy(
                        successor_facts.entry_invalid_owners[:],
                        block_facts.exit_invalid_owners[:],
                    )
                    copy(successor_facts.entry[:], block_facts.exit[:])
                    copy(
                        successor_facts.entry_invalid[:],
                        block_facts.exit_invalid[:],
                    )
                    changed = true
                    continue
                }
                for fact, index in block_facts.exit_owners {
                    if fact && !successor_facts.entry_owners[index] {
                        successor_facts.entry_owners[index] = true
                        changed = true
                    }
                }
                for fact, index in block_facts.exit_invalid_owners {
                    if fact && !successor_facts.entry_invalid_owners[index] {
                        successor_facts.entry_invalid_owners[index] = true
                        changed = true
                    }
                }
                for fact, index in block_facts.exit {
                    joined := Ownership_IR_Borrow_Fact{
                        may_borrowed =
                            successor_facts.entry[index].may_borrowed ||
                            fact.may_borrowed,
                        must_borrowed =
                            successor_facts.entry[index].must_borrowed &&
                            fact.must_borrowed,
                    }
                    if joined != successor_facts.entry[index] {
                        successor_facts.entry[index] = joined
                        changed = true
                    }
                }
                for fact, index in block_facts.exit_invalid {
                    joined := Ownership_IR_Borrow_Invalid_Fact{
                        may_invalid =
                            successor_facts.entry_invalid[index].may_invalid ||
                            fact.may_invalid,
                        must_invalid =
                            successor_facts.entry_invalid[index].must_invalid &&
                            fact.must_invalid,
                    }
                    if joined != successor_facts.entry_invalid[index] {
                        successor_facts.entry_invalid[index] = joined
                        changed = true
                    }
                }
            }
        }
        if !changed {
            analysis.converged = true
            break
        }
    }
    return analysis
}

ownership_ir_cleanup_need :: proc(
    fact: Ownership_IR_Live_Fact,
) -> Ownership_IR_Cleanup_Need {
    if !fact.may_live {
        return .None
    }
    return .Always if fact.must_live else .Conditional
}
