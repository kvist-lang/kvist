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
	Conditional_Multi_Result_Storage,
	Loop_Storage,
}

OWNERSHIP_CONTROL_FLOW_NAMES := [?]string{
	"conditional-construction",
	"conditional-storage",
	"conditional-multi-result-storage",
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

Nested_Scalar_Transfer :: enum {
	Return,
	Alias,
	Branch_Return,
}

NESTED_SCALAR_TRANSFER_NAMES := [?]string{
	"nested-scalar-return",
	"nested-scalar-alias",
	"nested-scalar-branch-return",
}

Native_Result_Wrapper :: enum {
	Direct,
	Alias,
	Do,
	Branch,
	Prefix,
	Direct_Return,
	Do_Direct_Return,
	Single_Binding,
}

NATIVE_RESULT_WRAPPER_NAMES := [?]string{
	"native-result-direct",
	"native-result-alias",
	"native-result-do",
	"native-result-branch",
	"native-result-prefix",
	"native-result-direct-return",
	"native-result-do-direct-return",
	"native-result-single-binding",
}

Conditional_Result_Order :: enum {
	Original,
	Reordered,
	Reordered_Aliases,
}

CONDITIONAL_RESULT_ORDER_NAMES := [?]string{
	"conditional-result-original",
	"conditional-result-reordered",
	"conditional-result-reordered-aliases",
}

Early_Return_Location :: enum {
	Procedure_Body,
	Let_Body,
	Do_Body,
	If_Condition,
	Binding_Value,
}

EARLY_RETURN_LOCATION_NAMES := [?]string{
	"early-return-procedure-body",
	"early-return-let-body",
	"early-return-do-body",
	"early-return-if-condition",
	"early-return-binding-value",
}

Condition_Mutation_Location :: enum {
	Source,
	Alias,
	If_Condition,
	Later_Binding,
	Toggle_Source,
	Pointer_Source,
}

CONDITION_MUTATION_LOCATION_NAMES := [?]string{
	"condition-mutation-source",
	"condition-mutation-alias",
	"condition-mutation-if-condition",
	"condition-mutation-later-binding",
	"condition-mutation-toggle-source",
	"condition-mutation-pointer-source",
}

Owned_Discard_Shape :: enum {
	Simple,
	Always_Left,
	Always_Right,
	Always_Both,
	Conditional_Status_Named,
	Conditional_Status_Discarded,
	Explicit_Simple,
	Explicit_Multi,
	Explicit_Conditional,
	Aggregate_Binding,
	Aggregate_Binding_Right,
	Explicit_Aggregate,
	Implicit_Aggregate,
	Union_Binding,
	Explicit_Union,
	Implicit_Union,
}

OWNED_DISCARD_SHAPE_NAMES := [?]string{
	"owned-discard-simple",
	"owned-discard-always-left",
	"owned-discard-always-right",
	"owned-discard-always-both",
	"owned-discard-conditional-status-named",
	"owned-discard-conditional-status-discarded",
	"owned-discard-explicit-simple",
	"owned-discard-explicit-multi",
	"owned-discard-explicit-conditional",
	"owned-discard-aggregate-binding",
	"owned-discard-aggregate-binding-right",
	"owned-discard-explicit-aggregate",
	"owned-discard-implicit-aggregate",
	"owned-discard-union-binding",
	"owned-discard-explicit-union",
	"owned-discard-implicit-union",
}

discarded_owned_results_are_cleaned_immediately :: proc(t: ^pbt.T) -> pbt.Result {
	shape := Owned_Discard_Shape(pbt.draw(t, pbt.int_range(0, len(OWNED_DISCARD_SHAPE_NAMES) - 1)))
	for name, index in OWNED_DISCARD_SHAPE_NAMES {
		pbt.cover(t, int(shape) == index, 2, name)
	}

	binding := "_ (strings.clone \"discarded\")"
	body := "    1"
	exercise_body := ""
	switch shape {
	case .Always_Left:
		binding = "[_ right] (clone-pair \"left\" \"right\")"
		body = "    (count right)"
	case .Always_Right:
		binding = "[left _] (clone-pair \"left\" \"right\")"
		body = "    (count left)"
	case .Always_Both:
		binding = "[_ _] (clone-pair \"left\" \"right\")"
	case .Conditional_Status_Named:
		binding = "[_ allocated?] (strings.replace \"hello\" \"e\" \"a\" -1)"
		body = "    (if allocated? 1 0)"
	case .Conditional_Status_Discarded:
		binding = "[_ _] (strings.replace \"hello\" \"e\" \"a\" -1)"
	case .Explicit_Simple:
		exercise_body = "  (discard (strings.clone \"discarded\"))\n  1"
	case .Explicit_Multi:
		exercise_body = "  (discard (clone-pair \"left\" \"right\"))\n  1"
	case .Explicit_Conditional:
		exercise_body = "  (discard (strings.replace \"hello\" \"e\" \"a\" -1))\n  1"
	case .Aggregate_Binding:
		binding = "[_ ok] (make-box)"
		body = "    (if ok 1 0)"
	case .Aggregate_Binding_Right:
		binding = "[ok _] (make-box-right)"
		body = "    (if ok 1 0)"
	case .Explicit_Aggregate:
		exercise_body = "  (discard (make-box))\n  1"
	case .Implicit_Aggregate:
		exercise_body = "  (make-box)\n  1"
	case .Union_Binding:
		binding = "[_ ok] (make-choice)"
		body = "    (if ok 1 0)"
	case .Explicit_Union:
		exercise_body = "  (discard (make-choice))\n  1"
	case .Implicit_Union:
		exercise_body = "  (make-choice)\n  1"
	case .Simple:
	}
	if exercise_body == "" {
		exercise_body = fmt.tprintf("  (let [%s]\n%s)", binding, body)
	}
	source := fmt.tprintf(`(package app)
(import strings "core:strings")

(defstruct Box [text: string])
(defunion Choice [text: string number: int])

(defn clone-pair [left: string right: string]
  -> [left-result: string, right-result: string]
  (return (strings.clone left) (strings.clone right)))

(defn make-box [] -> [box: Box, ok: bool]
  (return (Box :text (strings.clone "box")) true))

(defn make-box-right [] -> [ok: bool, box: Box]
  (return true (Box :text (strings.clone "box"))))

(defn make-choice [] -> [choice: Choice, ok: bool]
  (return (Choice :text (strings.clone "choice")) true))

(defn exercise [] -> int
%s)`, exercise_body)
	pbt.note(t, fmt.tprintf("shape=%s\n%s", OWNED_DISCARD_SHAPE_NAMES[shape], source))
	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated owned-discard program did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated owned-discard program emitted warning: %s", result.warnings[0].message))
	}
	if !strings.contains(result.output, "delete(kvist_thread_") {
		return pbt.fail("discarded owned result was not cleaned")
	}
	if strings.contains(result.output, "defer delete(kvist_thread_") ||
	   strings.contains(result.output, "_ = strings.clone") ||
	   strings.contains(result.output, "_, right :=") ||
	   strings.contains(result.output, "left, _ :=") {
		return pbt.fail("discarded owned result was not materialized for immediate cleanup")
	}
	return pbt.pass()
}

mutated_activation_siblings_block_conditional_cleanup_inference :: proc(t: ^pbt.T) -> pbt.Result {
	location := Condition_Mutation_Location(pbt.draw(t, pbt.int_range(0, len(CONDITION_MUTATION_LOCATION_NAMES) - 1)))
	for name, index in CONDITION_MUTATION_LOCATION_NAMES {
		pbt.cover(t, int(location) == index, 2, name)
	}

	body := "    (set! did-allocate? (not did-allocate?))\n    (return did-allocate? value)"
	bindings := "[[value did-allocate?] (strings.replace source old new -1)]"
	switch location {
	case .Alias:
		body = "    (let [condition did-allocate?]\n      (set! condition (not condition))\n      (return condition value))"
	case .If_Condition:
		body = "    (if (do (set! did-allocate? (not did-allocate?)) true)\n      (return did-allocate? value)\n      (return did-allocate? value))"
	case .Later_Binding:
		bindings = "[[value did-allocate?] (strings.replace source old new -1)\n        marker (do (set! did-allocate? (not did-allocate?)) true)]"
		body = "    (assert marker)\n    (return did-allocate? value)"
	case .Toggle_Source:
		body = "    (toggle! did-allocate?)\n    (return did-allocate? value)"
	case .Pointer_Source:
		body = "    (invert-bool! (addr did-allocate?))\n    (return did-allocate? value)"
	case .Source:
	}
	source := fmt.tprintf(`(package app)
(import strings "core:strings")

(defn invert-bool! [value: ^bool]
  (toggle! value^))

(defn replace-inverted [source: string old: string new: string]
  -> [allocated?: bool, result: string]
  (let %s
%s))

(defn exercise [] -> int
  (let [[allocated? value] (replace-inverted "hello" "z" "x")]
    (assert allocated?)
    (count value)))`, bindings, body)
	pbt.note(t, fmt.tprintf("location=%s\n%s", CONDITION_MUTATION_LOCATION_NAMES[location], source))
	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated condition-mutation wrapper did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if strings.contains(result.output, "delete(value)") {
		return pbt.fail("caller inferred cleanup from a mutated activation sibling")
	}
	return pbt.pass()
}

early_returns_block_tail_result_lifecycle_inference :: proc(t: ^pbt.T) -> pbt.Result {
	location := Early_Return_Location(pbt.draw(t, pbt.int_range(0, len(EARLY_RETURN_LOCATION_NAMES) - 1)))
	for name, index in EARLY_RETURN_LOCATION_NAMES {
		pbt.cover(t, int(location) == index, 2, name)
	}

	body := "  (let [[replaced did-allocate?] (strings.replace source \"e\" \"a\" -1)]\n    (when borrow? (return true source))\n    (return did-allocate? replaced))"
	switch location {
	case .Procedure_Body:
		body = "  (when borrow? (return true source))\n  (let [[replaced did-allocate?] (strings.replace source \"e\" \"a\" -1)]\n    (return did-allocate? replaced))"
	case .Do_Body:
		body = "  (let [[replaced did-allocate?] (strings.replace source \"e\" \"a\" -1)]\n    (do\n      (when borrow? (return true source))\n      (return did-allocate? replaced)))"
	case .If_Condition:
		body = "  (let [[replaced did-allocate?] (strings.replace source \"e\" \"a\" -1)]\n    (if (do (when borrow? (return true source)) true)\n      (return did-allocate? replaced)\n      (return did-allocate? replaced)))"
	case .Binding_Value:
		body = "  (let [[replaced did-allocate?] (strings.replace source \"e\" \"a\" -1)\n        marker (do (when borrow? (return true source)) true)]\n    (assert marker)\n    (return did-allocate? replaced))"
	case .Let_Body:
	}
	source := fmt.tprintf(`(package app)
(import strings "core:strings")

(defn maybe-replace [source: string borrow?: bool]
  -> [allocated?: bool, result: string]
%s)

(defn exercise [] -> int
  (let [[allocated? value] (maybe-replace "hello" true)]
    (assert allocated?)
    (count value)))`, body)
	pbt.note(t, fmt.tprintf("location=%s\n%s", EARLY_RETURN_LOCATION_NAMES[location], source))
	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated early-return wrapper did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if strings.contains(result.output, "delete(value)") {
		return pbt.fail("caller inferred cleanup from a tail whose prefix can return a borrowed result")
	}
	return pbt.pass()
}

conditional_owned_results_remap_their_activation_sibling :: proc(t: ^pbt.T) -> pbt.Result {
	order := Conditional_Result_Order(pbt.draw(t, pbt.int_range(0, len(CONDITIONAL_RESULT_ORDER_NAMES) - 1)))
	for name, index in CONDITIONAL_RESULT_ORDER_NAMES {
		pbt.cover(t, int(order) == index, 2, name)
	}

	return_body := "    (return value allocated?)"
	return_spec := "[result: string, did-allocate?: bool]"
	caller_pattern := "[value allocated?]"
	switch order {
	case .Reordered:
		return_body = "    (return allocated? value)"
		return_spec = "[did-allocate?: bool, result: string]"
		caller_pattern = "[allocated? value]"
	case .Reordered_Aliases:
		return_body = "    (let [result value did-allocate? allocated?]\n      (return did-allocate? result))"
		return_spec = "[did-allocate?: bool, result: string]"
		caller_pattern = "[allocated? value]"
	case .Original:
	}
	source := fmt.tprintf(`(package app)
(import strings "core:strings")

(defn replace-result [source: string old: string new: string] -> %s
  (let [[value allocated?] (strings.replace source old new -1)]
%s))

(defn exercise [] -> int
  (let [%s (replace-result "hello" "e" "a")]
    (assert allocated?)
    (count value)))`,
		return_spec,
		return_body,
		caller_pattern,
	)
	pbt.note(t, fmt.tprintf("order=%s\n%s", CONDITIONAL_RESULT_ORDER_NAMES[order], source))
	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated conditional-result wrapper did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated conditional-result wrapper emitted warning: %s", result.warnings[0].message))
	}
	if !strings.contains(result.output, "if allocated_p {") ||
	   !strings.contains(result.output, "delete(value)") {
		return pbt.fail("caller did not condition cleanup on the remapped allocation result")
	}
	if strings.contains(result.output, "defer delete(value)") {
		return pbt.fail("caller emitted unconditional cleanup for a conditional owned result")
	}
	return pbt.pass()
}

owned_native_multi_results_propagate_through_local_wrappers :: proc(t: ^pbt.T) -> pbt.Result {
	shape := Native_Result_Wrapper(pbt.draw(t, pbt.int_range(0, len(NATIVE_RESULT_WRAPPER_NAMES) - 1)))
	for name, index in NATIVE_RESULT_WRAPPER_NAMES {
		pbt.cover(t, int(shape) == index, 2, name)
	}

	body := "    (return cloned true)"
	prefix := ""
	function_body := ""
	signature := "[source: string]"
	call_args := "\"hello\""
	switch shape {
	case .Alias:
		body = "    (let [result cloned]\n      (return result true))"
	case .Do:
		body = "    (do\n      (assert true)\n      (return cloned true))"
	case .Branch:
		signature = "[source: string flag: bool]"
		call_args = "\"hello\" true"
		body = "    (if flag\n      (return cloned true)\n      (return cloned true))"
	case .Prefix:
		prefix = "  (assert (> (count source) 0))\n"
	case .Direct_Return:
		function_body = "  (return (strings.clone source) true)"
	case .Do_Direct_Return:
		function_body = "  (do\n    (assert (> (count source) 0))\n    (return (strings.clone source) true))"
	case .Single_Binding:
		function_body = "  (let [cloned (strings.clone source)]\n    (return cloned true))"
	case .Direct:
	}
	if function_body == "" {
		function_body = fmt.tprintf("%s  (let [[cloned error] (strings.clone source)]\n    (assert (= error nil))\n%s)", prefix, body)
	}
	source := fmt.tprintf(`(package app)
(import strings "core:strings")

(defn clone-text-result %s -> [value: string, ok: bool]
%s)

(defn exercise [] -> int
  (let [[value ok] (clone-text-result %s)]
    (assert ok)
    (count value)))`,
		signature,
		function_body,
		call_args,
	)
	pbt.note(t, fmt.tprintf("shape=%s\n%s", NATIVE_RESULT_WRAPPER_NAMES[shape], source))
	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated native-result wrapper did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated native-result wrapper emitted warning: %s", result.warnings[0].message))
	}
	if !strings.contains(result.output, "defer delete(value)") {
		return pbt.fail("caller did not acquire cleanup for the wrapped owned result")
	}
	if strings.contains(result.output, "defer delete(cloned)") ||
	   strings.contains(result.output, "defer delete(result)") {
		return pbt.fail("callee retained cleanup after returning the owned result")
	}
	return pbt.pass()
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
	case .Conditional_Multi_Result_Storage:
		strings.write_string(&builder, "(defn make-payload [marker: int] -> [payload: Payload, keep?: bool]\n  (return ")
		write_payload_constructor(&builder, named, "(clone-string \"left\")", "(clone-string \"right\")", "marker")
		strings.write_string(&builder, " (not (= marker 2))))\n\n(defn exercise [flag: bool] -> int\n  (let [[payload keep?] (make-payload 1)\n        items (make [dynamic]Payload) :defer-with delete-items]\n    (if flag\n      (append (addr items) payload)\n      (discard keep?))\n    (count items)))")
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
	if flow == .Conditional_Multi_Result_Storage &&
	   (!strings.contains(result.output, "kvist_owner_") ||
	    !strings.contains(result.output, "if kvist_owner^")) {
		return pbt.fail("conditional multi-result transfer did not receive guarded cleanup")
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
	overwrite_mode := pbt.draw(t, pbt.int_range(0, 2))
	depth := pbt.draw(t, pbt.int_range(0, 2))
	through_proc := pbt.draw(t, pbt.boolean())
	pbt.cover(t, named, 2, "named-owned-field")
	pbt.cover(t, !named, 2, "positional-owned-field")
	pbt.cover(t, conditional, 2, "conditional-owned-field-value")
	pbt.cover(t, !conditional, 2, "direct-owned-field-value")
	pbt.cover(t, overwrite_mode == 0, 2, "owned-field-scope-cleanup")
	pbt.cover(t, overwrite_mode == 1, 2, "owned-field-unsafe-overwrite")
	pbt.cover(t, overwrite_mode == 2, 2, "owned-field-delete-then-reassign")
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
	if overwrite_mode == 1 {
		fmt.sbprintf(
			&source_builder,
			"(set! owned%s (clone-string \"replacement\"))",
			field_path,
		)
	} else if overwrite_mode == 2 {
		fmt.sbprintf(
			&source_builder,
			"(delete owned%s)\n    (set! owned%s (clone-string \"replacement\"))",
			field_path,
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
		"named=%t conditional=%t overwrite-mode=%d depth=%d through-proc=%t\n%s",
		named,
		conditional,
		overwrite_mode,
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
	if overwrite_mode == 1 {
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

nested_owned_scalar_fields_preserve_transfer_cleanup :: proc(t: ^pbt.T) -> pbt.Result {
	depth := pbt.draw(t, pbt.int_range(0, 3))
	named := pbt.draw(t, pbt.boolean())
	through_proc := pbt.draw(t, pbt.boolean())
	through_parameter := pbt.draw(t, pbt.boolean())
	transfer := Nested_Scalar_Transfer(pbt.draw(t, pbt.int_range(0, len(NESTED_SCALAR_TRANSFER_NAMES) - 1)))
	for candidate in 0 ..= 3 {
		pbt.cover(t, depth == candidate, 1, fmt.tprintf("nested-scalar-depth-%d", candidate))
	}
	pbt.cover(t, named, 2, "nested-scalar-named")
	pbt.cover(t, !named, 2, "nested-scalar-positional")
	pbt.cover(t, through_proc, 2, "nested-scalar-through-procedure")
	pbt.cover(t, !through_proc, 2, "nested-scalar-direct-constructor")
	pbt.cover(t, through_parameter, 2, "nested-scalar-through-parameter")
	pbt.cover(t, !through_parameter, 2, "nested-scalar-local-owner")
	for name, index in NESTED_SCALAR_TRANSFER_NAMES {
		pbt.cover(t, int(transfer) == index, 2, name)
	}

	root_ty := "Leaf"
	field_path := ".text"
	declarations := "(defstruct Leaf [text: string])"
	if depth == 1 {
		root_ty = "Layer1"
		field_path = ".child.text"
		declarations = `(defstruct Leaf [text: string])
(defstruct Layer1 [child: Leaf])`
	} else if depth == 2 {
		root_ty = "Layer2"
		field_path = ".child.child.text"
		declarations = `(defstruct Leaf [text: string])
(defstruct Layer1 [child: Leaf])
(defstruct Layer2 [child: Layer1])`
	} else if depth == 3 {
		root_ty = "Layer3"
		field_path = ".child.child.child.text"
		declarations = `(defstruct Leaf [text: string])
(defstruct Layer1 [child: Leaf])
(defstruct Layer2 [child: Layer1])
(defstruct Layer3 [child: Layer2])`
	}

	constructor_left := nested_scalar_constructor_text(depth, named, `(clone-string "left")`)
	constructor_right := nested_scalar_constructor_text(depth, named, `(clone-string "right")`)
	maker := ""
	left_value := constructor_left
	right_value := constructor_right
	if through_proc {
		maker_constructor := nested_scalar_constructor_text(depth, named, `(clone-string source)`)
		maker = fmt.tprintf(
			"(defn make-owned [source: string] -> %s\n  %s)\n",
			root_ty,
			maker_constructor,
		)
		left_value = `(make-owned "left")`
		right_value = `(make-owned "right")`
	}

	body := ""
	switch transfer {
	case .Return:
		if through_parameter {
			body = fmt.tprintf(
				"(defn extract [owned: %s] -> string\n  owned%s)\n\n(defn exercise [] -> int\n  (let [owned %s\n        value (extract owned)]\n    (count value)))",
				root_ty,
				field_path,
				left_value,
			)
		} else {
			body = fmt.tprintf(
				"(defn extract [] -> string\n  (let [owned %s]\n    owned%s))\n\n(defn exercise [] -> int\n  (let [value (extract)]\n    (count value)))",
				left_value,
				field_path,
			)
		}
	case .Alias:
		if through_parameter {
			body = fmt.tprintf(
				"(defn extract [owned: %s] -> string\n  (let [moved owned%s]\n    moved))\n\n(defn exercise [] -> int\n  (let [owned %s\n        moved (extract owned) :defer-with delete-text]\n    (count moved)))",
				root_ty,
				field_path,
				left_value,
			)
		} else {
			body = fmt.tprintf(
				"(defn exercise [] -> int\n  (let [owned %s\n        moved owned%s :defer-with delete-text]\n    (count moved)))",
				left_value,
				field_path,
			)
		}
	case .Branch_Return:
		if through_parameter {
			body = fmt.tprintf(
				"(defn extract [left: %s right: %s left?: bool] -> string\n  (if left?\n    (do (delete right%s) left%s)\n    (do (delete left%s) right%s)))\n\n(defn exercise [] -> int\n  (let [left %s\n        right %s\n        value (extract left right true)]\n    (count value)))",
				root_ty,
				root_ty,
				field_path,
				field_path,
				field_path,
				field_path,
				left_value,
				right_value,
			)
		} else {
			body = fmt.tprintf(
				"(defn extract [left?: bool] -> string\n  (let [left %s\n        right %s]\n    (if left? left%s right%s)))\n\n(defn exercise [] -> int\n  (let [value (extract true)]\n    (count value)))",
				left_value,
				right_value,
				field_path,
				field_path,
			)
		}
	}
	source := fmt.tprintf(`(package app)
(import strings "core:strings")

%s

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn delete-text [value: string]
  (delete value))

%s
%s`, declarations, maker, body)
	pbt.note(t, fmt.tprintf(
		"depth=%d named=%t through-proc=%t through-parameter=%t transfer=%s\n%s",
		depth,
		named,
		through_proc,
		through_parameter,
		NESTED_SCALAR_TRANSFER_NAMES[transfer],
		source,
	))
	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated nested scalar transfer did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated nested scalar transfer emitted warning: %s", result.warnings[0].message))
	}
	switch transfer {
	case .Return:
		if !strings.contains(result.output, "delete(kvist_place^)") {
			return pbt.fail("nested scalar return did not install caller cleanup")
		}
	case .Alias:
		if !strings.contains(result.output, "defer delete_text(moved)") ||
		   strings.contains(result.output, fmt.tprintf("defer delete(owned%s)", field_path)) {
			return pbt.fail("nested scalar alias did not move cleanup to the alias")
		}
	case .Branch_Return:
		if !strings.contains(result.output, fmt.tprintf("delete(left%s)", field_path)) ||
		   !strings.contains(result.output, fmt.tprintf("delete(right%s)", field_path)) ||
		   !strings.contains(result.output, "delete(kvist_place^)") {
			return pbt.fail("nested scalar branch return did not clean the unselected owner and the caller result")
		}
	}
	if through_parameter &&
	   (strings.contains(result.output, fmt.tprintf("defer delete(owned%s)", field_path)) ||
	    strings.contains(result.output, fmt.tprintf("defer delete(left%s)", field_path)) ||
	    strings.contains(result.output, fmt.tprintf("defer delete(right%s)", field_path))) {
		return pbt.fail("owned parameter field retained source cleanup after transfer")
	}
	return pbt.pass()
}

nested_scalar_constructor_text :: proc(
	depth: int,
	named: bool,
	value: string,
) -> string {
	builder := strings.builder_make()
	defer strings.builder_destroy(&builder)
	for layer := depth; layer >= 1; layer -= 1 {
		fmt.sbprintf(
			&builder,
			"(Layer%d %s",
			layer,
			":child " if named else "",
		)
	}
	fmt.sbprintf(&builder, "(Leaf %s%s)", ":text " if named else "", value)
	for _ in 0 ..< depth {
		strings.write_byte(&builder, ')')
	}
	return strings.clone(strings.to_string(builder))
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
