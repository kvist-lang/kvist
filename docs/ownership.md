# Ownership And Deterministic Cleanup

Kvist uses one control-flow ownership engine for deterministic cleanup and
ownership diagnostics. It does not add ownership annotations to ordinary
Kvist code. Explicit Odin-style cleanup remains available, while cleanup is
inserted automatically when ownership, the destructor, and non-escape are all
proven.

The engine operates on semantic events after macro expansion and ownership
contract resolution. Syntax such as `delete`, a custom `release` call, a
return, or an owned argument is lowered before the dataflow analysis runs.
Consequently, adding another spelling for an existing operation should not
require another analysis rule.

## Ownership Events

Each local ownership place has `may_live` and `must_live` facts at every basic
block boundary. Branches join with logical OR for `may_live` and logical AND
for `must_live`; loops use the same finite lattice to a fixed point.

| Event | Meaning |
| --- | --- |
| `Acquire` | A new ownership obligation becomes live. |
| `Reassign` | New owned storage replaces the value in a place. A live old value can produce KVO004. |
| `Borrow` | The owned value is observed without transferring it. |
| `Copy` | Ownership facts are copied to another tracked place without clearing the source. This is reserved for values whose ownership contract permits it. |
| `Move` | Ownership moves to another local place and the source becomes empty. |
| `Store` | Ownership moves into tracked aggregate storage or leaves the local graph. |
| `Destroy` | Cleanup runs now. The ownership obligation ends and dependent borrows become invalid. |
| `Schedule_Destroy` | Cleanup is scheduled for scope exit. The value remains usable until that exit. |
| `Transfer` | A consuming call takes ownership. The local ownership obligation ends. |
| `Return` | Ownership leaves the procedure through a result. |
| `Discard` | A produced owned value is thrown away; this can produce KVO001. |
| `Call` | A sequencing point without an ownership effect of its own. |

`Destroy` is the common operation for explicit `delete` and recognized custom
destructors. The analysis does not diagnose by matching those source forms
after lowering.

## Borrow Events

Borrow provenance is a separate dataflow lattice because a value can be
borrowed on every path while referring to different owners on those paths.
The engine therefore tracks both row-level `may`/`must` facts and the set of
possible owners.

| Event | Meaning |
| --- | --- |
| `Borrow_Assign` | A borrower is assigned a view of one owner. Previous provenance and invalidation are cleared. |
| `Borrow_Copy` | Active and invalid provenance are copied through a local alias. |
| `Borrow_Clear` | Assignment of an owned or independent value removes borrowed provenance. |
| `Borrow_Use` | The value is actually consumed or inspected. An invalid borrow produces KVO005 here. |
| `Borrow_Escape` | A borrowed value leaves through a return or returned composite. |
| `Borrow_Delete` | Cleanup is attempted on a borrowed value, producing KVO006. |
| `Borrow_Owner_Exit` | A borrowed value crosses a cleanup boundary belonging to its owner. |

When `Destroy` runs, active owner relations move to invalid-owner relations.
If every incoming path has lost its owner, a later use is definite. If only
some paths destroyed the owner, the finding is conservative. Reassigning the
borrower clears the stale relation, and a stale value that is never used does
not produce a use-after-destroy warning.

## Cleanup Planning

Each reachable procedure exit receives a cleanup need:

- `None`: no ownership obligation reaches the exit;
- `Always`: every path reaching the exit owns the value;
- `Conditional`: only some paths own it.

Uniform actions can become one scope `defer`. Mixed actions are emitted on
individual return, break, continue, or fallthrough edges when the emitter can
preserve evaluation order. Native strings, slices, dynamic arrays, SOA values,
and maps use known `delete` semantics. Managed `Data` and supported aggregates
use their structural lifecycle. Opaque resources require an exact destructor
contract or explicit cleanup.

Opaque foreign calls enter the same model through exact `Ownership_Call_Contract`
records. One normalization step converts a contract's result flow, cleanup
policy, activation condition, and result type into the result lifecycle used by
lowering. The resulting `contract_cleanup` need is an adoption guard for the
canonical IR plan, not a second diagnostic engine.

Before emission, an independent verifier checks the completed plan against the
control-flow analysis and lowered ownership metadata. Every tracked lexical
exit must have exactly one matching action; action reachability and cleanup
need must agree with dataflow; places, owner groups, projections, cleanup
metadata, and boundary blocks must be valid; and a scheduled destructor cannot
also authorize automatic cleanup. Verification failure is an internal compiler
error, so an inconsistent plan cannot silently become generated Odin.

KVO001–KVO006 and KVO008 are created as facts by the ownership plan and
formatted centrally. KVO007 remains a deliberately syntactic warning because
it explains when a source-level `defer` inside a loop executes rather than
reasoning about ownership state.

## Manual Control

Automatic cleanup is optional in the practical sense: writing `delete`,
`defer`, `errdefer`, or the exact custom destructor remains valid and visible
in generated Odin. The engine accounts for those operations so it does not
also emit an automatic destructor on the same path. Ambiguous ownership,
unknown native destructors, captures, and unsupported storage intentionally
fall back to explicit cleanup with a diagnostic where useful.

This preserves the important Odin properties: deterministic destruction,
allocator choice, inspectable generated code, explicit transfer, and the
ability to manage resources manually where that control matters.

## Deliberate Boundaries

The completed local engine tracks named locals, supported aggregate fields,
aliases, branches, loops, and lexical exits. The following are separate future
features rather than missing special cases in this engine:

- arbitrary borrows stored inside general containers;
- borrow provenance captured by closures;
- field-sensitive provenance for every imported or union representation;
- whole-program lifetime proofs across unknown foreign calls;
- automatic cleanup for opaque resources without an exact destructor and
  success-condition contract.

Until those features have explicit representations, Kvist remains
conservative: it skips automatic cleanup or asks for explicit ownership rather
than guessing. Extending one of these boundaries should introduce a general
place, relation, or call-contract capability and corresponding control-flow
tests—not a new surface annotation or a source-spelling exception.
