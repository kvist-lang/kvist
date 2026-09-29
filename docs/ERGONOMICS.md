# Kvist Ergonomics

Kvist borrows Clojure's expression-oriented, data-first programming model
without adopting ambient laziness, universal boxing, runtime Vars, dynamic
ordinary dispatch, or tracing garbage collection. Native values retain Odin
representation and cost.

Kvist infers transfer facts from ordinary control flow. Owned native strings,
slices, dynamic arrays, SOA values, and maps get deterministic scope cleanup
when their type, ownership, and non-escape are proven. `Data` and supported
aggregates use their structural lifecycle. Opaque native resources retain
explicit Odin-style cleanup unless an exact foreign-result contract identifies
their destructor and success condition.

## Design Constraints

- Native structs and homogeneous collections are the ordinary internal
  representation.
- Sequence operations are eager unless a transform explicitly fuses them.
- `Data` is immutable, deterministic, cycle-free through its public API, and
  visible in signatures.
- Ordinary calls do not use hidden boxing or runtime dispatch.
- Ownership crossings are explicit, and exceptions are not the normal error
  path.
- Opaque native resources use explicit cleanup unless exact binding metadata
  proves the result lifecycle. Procedure names such as `Type-destroy` and
  `Type-clone` do not define a managed-type protocol.

## Current Capabilities

- `:defer`, `:defer-with`, and `:errdefer` provide scoped cleanup.
- Proven non-escaping native allocations receive generated scope cleanup;
  explicit cleanup remains available when the transfer is ambiguous or the
  custom destructor is not covered by exact metadata.
- Multi-return calls can describe ownership per result. The regex package uses
  this for conditional cleanup of successfully compiled regexes and allocated
  captures. `os.read_entire_file` uses unconditional cleanup because an error
  may accompany a partial allocation. File handles returned by `os.open`,
  `os.create`, and `os.clone` use conditional `os.close` cleanup after success.
  Simple wrapper procedures inherit these result contracts. This is compiler
  metadata and body inference, not ownership syntax.
- Closure capture and aggregate or mutable storage block automatic result
  cleanup. Ownership audit reports `KVO008` with an explicit-cleanup or
  transfer hint instead of risking an early destructor.
- Ownership diagnostics distinguish definite findings from conservative audit
  findings. `kvist lifetimes` explains inferred allocation, borrowing, and
  transfer boundaries.
- Borrow provenance flows through local aliases, assignments, and branches.
  Deleting a definitely borrowed value reports definite `KVO006`; a value
  borrowed on only some paths is retained as a conservative finding. KVO005
  also follows owner cleanup through fallthrough, `break`, and `continue`.
  Explicit destruction invalidates dependent views in the same dataflow:
  `KVO005` is reported at a later use, propagates through aliases, becomes
  conservative when destruction is branch-dependent, and stays silent when
  the stale view is never used or is reassigned first.
- Top-level Kvist structs manage `Data` fields through construction, copying,
  updates, moves, returns, and destruction.
- `data.decode` and `data.validate` support scalar values, enums, nested
  structs, defaults, and typed dynamic arrays with precise error paths.
- Structural `Data` destructuring and `match` support nested sequential and map
  patterns, literals, optional keys, defaults, and rest bindings.
- Source maps, diagnostics, generated package graphs, and per-package emission
  artifacts participate in the compilation cache.
- The native REPL supports persistent definitions and values, compatible
  redefinition, source tooling, debugging, and attachment to reload-enabled
  applications.

## Areas of Development

The local ownership and deterministic-cleanup engine is considered complete
for named locals, supported aggregate fields, ordinary control flow, and
lexical exits. See [Ownership And Deterministic Cleanup](ownership.md) for its
event model and the boundary between this milestone and later interprocedural
or container-sensitive work.

- More path-sensitive ownership analysis, especially ownership transferred
  through closures and containers, and broader exact foreign-binding metadata.
- Managed values inside native containers, unions, closures, local structs,
  and imported structs.
- Public builders for efficient incremental `Data` construction.
- Persisted parsed and macro-expanded package state.
- Source mapping for more generated cleanup, specialization, and macro forms.
- Dedicated editor presentation for lifetime information and Kvist language
  tooling.
