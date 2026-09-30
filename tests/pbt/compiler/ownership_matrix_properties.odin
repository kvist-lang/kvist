package main

import "core:fmt"
import "core:strings"

import pbt "pbt:pbt"
import kvist "../../../src/odin/kvist"

Ownership_Destination :: enum {
	Return,
	Fixed_Array,
	Dynamic_Array,
	Consuming_Call,
	Outer_Struct,
}

OWNERSHIP_DESTINATION_NAMES := [?]string{
	"return",
	"fixed-array",
	"dynamic-array",
	"consuming-call",
	"outer-struct",
}

Ownership_Control_Flow :: enum {
	Conditional_Construction,
	Conditional_Storage,
	Loop_Storage,
}

OWNERSHIP_CONTROL_FLOW_NAMES := [?]string{
	"conditional-construction",
	"conditional-storage",
	"loop-storage",
}

Ownership_Duplicate_Kind :: enum {
	Leaf,
	Aggregate,
	Fixed_Array,
	Consuming_Call,
}

OWNERSHIP_DUPLICATE_NAMES := [?]string{
	"leaf",
	"aggregate",
	"fixed-array",
	"consuming-call",
}

multiple_owned_leaves_transfer_across_aggregate_boundaries :: proc(t: ^pbt.T) -> pbt.Result {
	leaf_count := pbt.draw(t, pbt.int_range(2, 4))
	destination := Ownership_Destination(pbt.draw(t, pbt.int_range(0, len(OWNERSHIP_DESTINATION_NAMES) - 1)))
	named := pbt.draw(t, pbt.boolean())
	for count in 2 ..= 4 {
		pbt.cover(t, leaf_count == count, 1, fmt.tprintf("owned-leaves-%d", count + 1))
	}
	for name, index in OWNERSHIP_DESTINATION_NAMES {
		pbt.cover(t, int(destination) == index, 1, name)
	}
	pbt.cover(t, named, 2, "named-constructors")
	pbt.cover(t, !named, 2, "positional-constructors")

	builder: strings.Builder
	strings.builder_init(&builder, t.value_allocator)
	defer strings.builder_destroy(&builder)
	write_multiple_leaf_prelude(&builder, leaf_count, destination)
	write_multiple_leaf_exercise(&builder, leaf_count, destination, named)
	source := strings.to_string(builder)
	pbt.note(t, fmt.tprintf(
		"leaves=%d destination=%s named=%t\n%s",
		leaf_count + 1,
		OWNERSHIP_DESTINATION_NAMES[destination],
		named,
		source,
	))
	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated multi-leaf program did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated multi-leaf program emitted warning: %s", result.warnings[0].message))
	}

	for index in 0 ..< leaf_count {
		if cleanup_exists(result.output, fmt.tprintf("value%d", index), "") ||
		   cleanup_exists(result.output, "payload", fmt.tprintf(".value%d", index)) ||
		   cleanup_exists(result.output, "envelope", fmt.tprintf(".payload.value%d", index)) {
			return pbt.fail(fmt.tprintf("owned leaf %d retained cleanup after transfer", index))
		}
	}
	if cleanup_exists(result.output, "tail", "") ||
	   cleanup_exists(result.output, "envelope", ".tail") {
		return pbt.fail("owned tail retained cleanup after transfer")
	}
	return pbt.pass()
}

owned_aggregates_transfer_through_branches_and_loops :: proc(t: ^pbt.T) -> pbt.Result {
	flow := Ownership_Control_Flow(pbt.draw(t, pbt.int_range(0, len(OWNERSHIP_CONTROL_FLOW_NAMES) - 1)))
	named := pbt.draw(t, pbt.boolean())
	for name, index in OWNERSHIP_CONTROL_FLOW_NAMES {
		pbt.cover(t, int(flow) == index, 2, name)
	}
	pbt.cover(t, named, 2, "named-constructors")
	pbt.cover(t, !named, 2, "positional-constructors")

	builder: strings.Builder
	strings.builder_init(&builder, t.value_allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `(package app)
(import strings "core:strings")

(defstruct Payload [left: string right: string marker: int])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn delete-items [items: [dynamic]Payload]
  (for [item items]
    (delete item.left)
    (delete item.right))
  (delete items))

`)
	switch flow {
	case .Conditional_Construction:
		strings.write_string(&builder, "(defn exercise [flag: bool] -> int\n  (let [left (clone-string \"left\")\n        right (clone-string \"right\")\n        payload (if flag\n          ")
		write_payload_constructor(&builder, named, "left", "right", "1")
		strings.write_string(&builder, "\n          ")
		write_payload_constructor(&builder, named, "left", "right", "2")
		strings.write_string(&builder, ")\n        items (make [dynamic]Payload) :defer-with delete-items]\n    (append (addr items) payload)\n    (count items)))")
	case .Conditional_Storage:
		strings.write_string(&builder, "(defn exercise [flag: bool] -> int\n  (let [left (clone-string \"left\")\n        right (clone-string \"right\")\n        payload ")
		write_payload_constructor(&builder, named, "left", "right", "1")
		strings.write_string(&builder, "\n        items (make [dynamic]Payload) :defer-with delete-items]\n    (if flag\n      (append (addr items) payload)\n      (append (addr items) payload))\n    (count items)))")
	case .Loop_Storage:
		strings.write_string(&builder, "(defn exercise [_flag: bool] -> int\n  (let [items (make [dynamic]Payload) :defer-with delete-items]\n    (for [index ([3]int [0 1 2])]\n      (let [left (clone-string \"left\")\n            right (clone-string \"right\")\n            payload ")
		write_payload_constructor(&builder, named, "left", "right", "index")
		strings.write_string(&builder, "]\n        (append (addr items) payload)))\n    (count items)))")
	}
	source := strings.to_string(builder)
	pbt.note(t, fmt.tprintf("flow=%s named=%t\n%s", OWNERSHIP_CONTROL_FLOW_NAMES[flow], named, source))

	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated control-flow ownership program did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated control-flow ownership program emitted warning: %s", result.warnings[0].message))
	}
	if cleanup_exists(result.output, "left", "") ||
	   cleanup_exists(result.output, "right", "") ||
	   cleanup_exists(result.output, "payload", ".left") ||
	   cleanup_exists(result.output, "payload", ".right") {
		return pbt.fail("branch or loop transfer retained cleanup on an intermediate owner")
	}
	return pbt.pass()
}

duplicate_ownership_transfers_are_diagnosed :: proc(t: ^pbt.T) -> pbt.Result {
	kind := Ownership_Duplicate_Kind(pbt.draw(t, pbt.int_range(0, len(OWNERSHIP_DUPLICATE_NAMES) - 1)))
	for name, index in OWNERSHIP_DUPLICATE_NAMES {
		pbt.cover(t, int(kind) == index, 2, name)
	}

	builder: strings.Builder
	strings.builder_init(&builder, t.value_allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `(package app)
(import strings "core:strings")

(defstruct Leaf [text: string])
(defstruct Outer [leaf: Leaf])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn consume [value: Leaf] -> int
  (defer (delete value.text))
  (count value.text))

(defn exercise [] -> int
`)
	switch kind {
	case .Leaf:
		strings.write_string(&builder, `  (let [owned (clone-string "owned")
        first (Leaf :text owned)
        second (Leaf :text owned)]
    (+ (count first.text) (count second.text))))`)
	case .Aggregate:
		strings.write_string(&builder, `  (let [owned (clone-string "owned")
        leaf (Leaf :text owned)
        first (Outer :leaf leaf)
        second (Outer :leaf leaf)]
    (+ (count first.leaf.text) (count second.leaf.text))))`)
	case .Fixed_Array:
		strings.write_string(&builder, `  (let [owned (clone-string "owned")
        leaf (Leaf :text owned)
        first ([1]Leaf [leaf])
        second ([1]Leaf [leaf])]
    (+ (count first[0].text) (count second[0].text))))`)
	case .Consuming_Call:
		strings.write_string(&builder, `  (let [owned (clone-string "owned")
        leaf (Leaf :text owned)
        consumed-size (consume leaf)
        outer (Outer :leaf leaf)]
    (+ consumed-size (count outer.leaf.text))))`)
	}
	source := strings.to_string(builder)
	pbt.note(t, fmt.tprintf("duplicate=%s\n%s", OWNERSHIP_DUPLICATE_NAMES[kind], source))

	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated duplicate-transfer program did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	for warning in result.warnings {
		if warning.code == .Ownership_Use_After_Transfer &&
		   warning.confidence == .Definite {
			return pbt.pass()
		}
	}
	return pbt.fail("duplicate ownership transfer did not emit definite KVO003")
}

conditional_owned_results_preserve_cleanup :: proc(t: ^pbt.T) -> pbt.Result {
	field_count := pbt.draw(t, pbt.int_range(1, 3))
	wrap_else_in_do := pbt.draw(t, pbt.boolean())
	transfer_to_alias := pbt.draw(t, pbt.boolean())
	for count in 1 ..= 3 {
		pbt.cover(t, field_count == count, 1, fmt.tprintf("result-fields-%d", count))
	}
	pbt.cover(t, wrap_else_in_do, 2, "do-wrapped-branch")
	pbt.cover(t, !wrap_else_in_do, 2, "direct-branch")
	pbt.cover(t, transfer_to_alias, 2, "explicit-alias-cleanup")
	pbt.cover(t, !transfer_to_alias, 2, "automatic-result-cleanup")

	builder: strings.Builder
	strings.builder_init(&builder, t.value_allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `(package app)
(import strings "core:strings")

(defstruct Payload [`)
	for index in 0 ..< field_count {
		fmt.sbprintf(&builder, "value%d: string ", index)
	}
	strings.write_string(&builder, `marker: int])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn make-payload [marker: int] -> Payload
  (Payload`)
	for index in 0 ..< field_count {
		fmt.sbprintf(&builder, " :value%d (clone-string \"value%d\")", index, index)
	}
	strings.write_string(&builder, " :marker marker))\n\n(defn delete-payload [payload: Payload]\n")
	for index in 0 ..< field_count {
		fmt.sbprintf(&builder, "  (delete payload.value%d)\n", index)
	}
	strings.write_string(&builder, `)

(defn exercise [flag: bool] -> int
  (let [payload (if flag (make-payload 1) `)
	if wrap_else_in_do {
		strings.write_string(&builder, "(do (make-payload 2)))")
	} else {
		strings.write_string(&builder, "(make-payload 2))")
	}
	if transfer_to_alias {
		strings.write_string(&builder, "\n        moved payload :defer-with delete-payload]\n    moved.marker))")
	} else {
		strings.write_string(&builder, "]\n    payload.marker))")
	}
	source := strings.to_string(builder)
	pbt.note(t, fmt.tprintf(
		"fields=%d do=%t alias=%t\n%s",
		field_count,
		wrap_else_in_do,
		transfer_to_alias,
		source,
	))

	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated conditional-result program did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated conditional-result program emitted warning: %s", result.warnings[0].message))
	}
	for index in 0 ..< field_count {
		has_cleanup := cleanup_exists(
			result.output,
			"payload",
			fmt.tprintf(".value%d", index),
		)
		if has_cleanup == transfer_to_alias {
			return pbt.fail(fmt.tprintf("conditional result field %d has the wrong cleanup owner", index))
		}
	}
	if transfer_to_alias && !strings.contains(result.output, "defer delete_payload(moved)") {
		return pbt.fail("explicit cleanup on aggregate alias was not emitted")
	}
	return pbt.pass()
}

owned_struct_payloads_transfer_into_unions :: proc(t: ^pbt.T) -> pbt.Result {
	named := pbt.draw(t, pbt.boolean())
	staged := pbt.draw(t, pbt.boolean())
	pbt.cover(t, named, 2, "named-union-constructor")
	pbt.cover(t, !named, 2, "positional-union-constructor")
	pbt.cover(t, staged, 2, "staged-union-payload")
	pbt.cover(t, !staged, 2, "direct-union-payload")

	builder: strings.Builder
	strings.builder_init(&builder, t.value_allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `(package app)
(import strings "core:strings")

(defstruct Owned [text: string])
(defunion Choice [owned: Owned raw: int])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn delete-choice [choice: Choice]
  (case choice
    (Owned value) (delete value.text)
    (int _) (discard 0)
    (discard 0)))

(defn exercise [] -> int
  (let [`)
	if staged {
		strings.write_string(&builder, "text (clone-string \"owned\")\n        owned (Owned :text text)\n        choice ")
		if named {
			strings.write_string(&builder, "(Choice :owned owned)")
		} else {
			strings.write_string(&builder, "(Choice owned)")
		}
	} else {
		strings.write_string(&builder, "choice ")
		if named {
			strings.write_string(&builder, "(Choice :owned (Owned :text (clone-string \"owned\")))")
		} else {
			strings.write_string(&builder, "(Choice (Owned (clone-string \"owned\")))")
		}
	}
	strings.write_string(&builder, ` :defer-with delete-choice]
    (case choice (Owned value) (count value.text) 0)))`)
	source := strings.to_string(builder)
	pbt.note(t, fmt.tprintf("named=%t staged=%t\n%s", named, staged, source))

	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated union ownership program did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated union ownership program emitted warning: %s", result.warnings[0].message))
	}
	if strings.contains(result.output, "defer delete(text)") ||
	   strings.contains(result.output, "defer delete(owned.text)") {
		return pbt.fail("union payload retained cleanup on its source owner")
	}
	if !strings.contains(result.output, "defer delete_choice(choice)") {
		return pbt.fail("union payload destination did not retain explicit cleanup")
	}
	return pbt.pass()
}

owned_scalar_payloads_transfer_into_unions :: proc(t: ^pbt.T) -> pbt.Result {
	named := pbt.draw(t, pbt.boolean())
	direct := pbt.draw(t, pbt.boolean())
	multiple_owned_variants := pbt.draw(t, pbt.boolean())
	pbt.cover(t, named, 2, "named-scalar-union")
	pbt.cover(t, !named, 2, "positional-scalar-union")
	pbt.cover(t, direct, 2, "direct-scalar-payload")
	pbt.cover(t, !direct, 2, "staged-scalar-payload")
	pbt.cover(t, multiple_owned_variants, 2, "multiple-owned-union-variants")
	pbt.cover(t, !multiple_owned_variants, 2, "single-owned-union-variant")

	prefix := ""
	payload := "(clone-string \"owned\")"
	if !direct {
		prefix = "text (clone-string \"owned\")\n        "
		payload = "text"
	}
	constructor := fmt.tprintf(
		"(Choice %s%s)",
		":text " if named else "",
		payload,
	)
	union_variants := "text: string raw: int"
	extra_cleanup := ""
	if multiple_owned_variants {
		union_variants = "text: string values: [dynamic]int raw: int"
		extra_cleanup = "    ([dynamic]int values) (delete values)\n"
	}
	source := fmt.tprintf(`(package app)
(import strings "core:strings")

(defunion Choice [%s])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn delete-choice [choice: Choice]
  (case choice
    (string value) (delete value)
%s    (int _) (discard 0)
    (discard 0)))

(defn exercise [] -> int
  (let [%schoice %s :defer-with delete-choice]
    (case choice (string value) (count value) 0)))`,
		union_variants,
		extra_cleanup,
		prefix,
		constructor,
	)
	pbt.note(t, fmt.tprintf(
		"named=%t direct=%t multiple-owned=%t\n%s",
		named,
		direct,
		multiple_owned_variants,
		source,
	))

	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated scalar union program did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated scalar union program emitted warning: %s", result.warnings[0].message))
	}
	if strings.contains(result.output, "defer delete(text)") {
		return pbt.fail("scalar union payload retained cleanup on its source owner")
	}
	if !strings.contains(result.output, "defer delete_choice(choice)") {
		return pbt.fail("scalar union destination did not retain explicit cleanup")
	}
	return pbt.pass()
}

direct_owned_struct_fields_match_cleanup_rules :: proc(t: ^pbt.T) -> pbt.Result {
	named := pbt.draw(t, pbt.boolean())
	conditional := pbt.draw(t, pbt.boolean())
	overwrite := pbt.draw(t, pbt.boolean())
	depth := pbt.draw(t, pbt.int_range(0, 2))
	through_proc := pbt.draw(t, pbt.boolean())
	pbt.cover(t, named, 2, "named-owned-field")
	pbt.cover(t, !named, 2, "positional-owned-field")
	pbt.cover(t, conditional, 2, "conditional-owned-field-value")
	pbt.cover(t, !conditional, 2, "direct-owned-field-value")
	pbt.cover(t, overwrite, 2, "owned-field-overwrite")
	pbt.cover(t, !overwrite, 2, "owned-field-scope-cleanup")
	for candidate in 0 ..= 2 {
		pbt.cover(t, depth == candidate, 1, fmt.tprintf("direct-field-depth-%d", candidate))
	}
	pbt.cover(t, through_proc, 2, "owned-field-through-procedure")
	pbt.cover(t, !through_proc, 2, "owned-field-direct-constructor")

	owned_value := "(clone-string \"owned\")"
	if conditional {
		owned_value = "(if true (clone-string \"left\") (clone-string \"right\"))"
	}
	declarations := "(defstruct Leaf [text: string])"
	field_path := ".text"
	root_ty := "Leaf"
	if depth == 1 {
		declarations = `(defstruct Leaf [text: string])
(defstruct Layer1 [child: Leaf])`
		field_path = ".child.text"
		root_ty = "Layer1"
	} else if depth == 2 {
		declarations = `(defstruct Leaf [text: string])
(defstruct Layer1 [child: Leaf])
(defstruct Layer2 [child: Layer1])`
		field_path = ".child.child.text"
		root_ty = "Layer2"
	}
	constructor_builder: strings.Builder
	strings.builder_init(&constructor_builder, t.value_allocator)
	defer strings.builder_destroy(&constructor_builder)
	if depth == 2 {
		strings.write_string(&constructor_builder, "(Layer2 :child " if named else "(Layer2 ")
	}
	if depth >= 1 {
		strings.write_string(&constructor_builder, "(Layer1 :child " if named else "(Layer1 ")
	}
	fmt.sbprintf(
		&constructor_builder,
		"(Leaf %s%s)",
		":text " if named else "",
		owned_value,
	)
	for _ in 0 ..< depth {
		strings.write_string(&constructor_builder, ")")
	}
	binding_value := strings.to_string(constructor_builder)
	maker := ""
	if through_proc {
		maker = fmt.tprintf(
			"(defn make-owned [] -> %s\n  %s)\n",
			root_ty,
			binding_value,
		)
		binding_value = "(make-owned)"
	}
	defer if through_proc {
		delete(maker)
	}

	source_builder: strings.Builder
	strings.builder_init(&source_builder, t.value_allocator)
	defer strings.builder_destroy(&source_builder)
	fmt.sbprintf(&source_builder, `(package app)
(import strings "core:strings")

%s

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

%s
(defn exercise [] -> int
  (let [owned %s]
    `,
		declarations,
		maker,
		binding_value,
	)
	if overwrite {
		fmt.sbprintf(
			&source_builder,
			"(set! owned%s (clone-string \"replacement\"))",
			field_path,
		)
	} else {
		strings.write_string(&source_builder, "(discard 0)")
	}
	fmt.sbprintf(
		&source_builder,
		"\n    (count owned%s)))",
		field_path,
	)
	source := strings.to_string(source_builder)
	pbt.note(t, fmt.tprintf(
		"named=%t conditional=%t overwrite=%t depth=%d through-proc=%t\n%s",
		named,
		conditional,
		overwrite,
		depth,
		through_proc,
		source,
	))
	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated direct-field program did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if overwrite {
		for warning in result.warnings {
			if warning.code == .Ownership_Overwrite &&
			   warning.confidence == .Definite {
				return pbt.pass()
			}
		}
		return pbt.fail("owned direct field overwrite did not emit definite KVO004")
	}
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated direct-field program emitted warning: %s", result.warnings[0].message))
	}
	if !cleanup_exists(result.output, "owned", field_path) {
		return pbt.fail("direct owned struct field did not receive scoped cleanup")
	}
	return pbt.pass()
}

write_multiple_leaf_prelude :: proc(
	builder: ^strings.Builder,
	leaf_count: int,
	destination: Ownership_Destination,
) {
	strings.write_string(builder, `(package app)
(import strings "core:strings")

(defstruct Payload [`)
	for index in 0 ..< leaf_count {
		fmt.sbprintf(builder, "value%d: string ", index)
	}
	strings.write_string(builder, "marker: int])\n(defstruct Envelope [payload: Payload tail: string])\n")
	if destination == .Outer_Struct {
		strings.write_string(builder, "(defstruct Wrapper [envelope: Envelope])\n")
	}
	strings.write_string(builder, `
(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

`)
	if destination == .Dynamic_Array {
		strings.write_string(builder, "(defn delete-items [items: [dynamic]Envelope]\n  (for [item items]\n")
		for index in 0 ..< leaf_count {
			fmt.sbprintf(builder, "    (delete item.payload.value%d)\n", index)
		}
		strings.write_string(builder, "    (delete item.tail))\n  (delete items))\n\n")
	} else if destination == .Consuming_Call {
		strings.write_string(builder, "(defn consume [consumed: Envelope] -> int\n")
		for index in 0 ..< leaf_count {
			fmt.sbprintf(builder, "  (defer (delete consumed.payload.value%d))\n", index)
		}
		strings.write_string(builder, "  (defer (delete consumed.tail))\n  consumed.payload.marker)\n\n")
	}
}

write_multiple_leaf_exercise :: proc(
	builder: ^strings.Builder,
	leaf_count: int,
	destination: Ownership_Destination,
	named: bool,
) {
	switch destination {
	case .Return:
		strings.write_string(builder, "(defn exercise [] -> Envelope\n")
	case .Fixed_Array:
		strings.write_string(builder, "(defn exercise [] -> [1]Envelope\n")
	case .Dynamic_Array, .Consuming_Call:
		strings.write_string(builder, "(defn exercise [] -> int\n")
	case .Outer_Struct:
		strings.write_string(builder, "(defn exercise [] -> Wrapper\n")
	}
	strings.write_string(builder, "  (let [")
	for index in 0 ..< leaf_count {
		fmt.sbprintf(builder, "value%d (clone-string \"value%d\")\n        ", index, index)
	}
	strings.write_string(builder, "payload (Payload")
	for index in 0 ..< leaf_count {
		if named {
			fmt.sbprintf(builder, " :value%d value%d", index, index)
		} else {
			fmt.sbprintf(builder, " value%d", index)
		}
	}
	if named {
		strings.write_string(builder, " :marker 7)")
	} else {
		strings.write_string(builder, " 7)")
	}
	strings.write_string(builder, "\n        tail (clone-string \"tail\")\n        envelope ")
	if named {
		strings.write_string(builder, "(Envelope :payload payload :tail tail)")
	} else {
		strings.write_string(builder, "(Envelope payload tail)")
	}
	if destination == .Dynamic_Array {
		strings.write_string(builder, "\n        items (make [dynamic]Envelope) :defer-with delete-items")
	} else if destination == .Outer_Struct {
		strings.write_string(builder, "\n        wrapper (Wrapper :envelope envelope)")
	}
	strings.write_string(builder, "]\n    ")
	switch destination {
	case .Return:
		strings.write_string(builder, "envelope))")
	case .Fixed_Array:
		strings.write_string(builder, "[envelope]))")
	case .Dynamic_Array:
		strings.write_string(builder, "(append (addr items) envelope)\n    (count items)))")
	case .Consuming_Call:
		strings.write_string(builder, "(consume envelope)))")
	case .Outer_Struct:
		strings.write_string(builder, "wrapper))")
	}
}

write_payload_constructor :: proc(
	builder: ^strings.Builder,
	named: bool,
	left, right, marker: string,
) {
	if named {
		fmt.sbprintf(builder, "(Payload :left %s :right %s :marker %s)", left, right, marker)
	} else {
		fmt.sbprintf(builder, "(Payload %s %s %s)", left, right, marker)
	}
}

cleanup_exists :: proc(output, root, suffix: string) -> bool {
	return strings.contains(output, fmt.tprintf("defer delete(%s%s)", root, suffix))
}
