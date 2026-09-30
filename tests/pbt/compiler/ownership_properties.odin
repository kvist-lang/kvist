package main

import "core:fmt"
import "core:strings"

import pbt "pbt:pbt"
import kvist "../../../src/odin/kvist"

POD_FIELD_TYPES := [?]string{"bool", "Phase", "int", "i64", "u32"}
POD_FIELD_VALUES := [?]string{"true", "Phase.ready", "7", "11", "13"}
POD_ALTERNATE_VALUES := [?]string{"false", "Phase.unknown", "0", "17", "19"}

nested_owned_aggregate_transfers_preserve_the_final_owner :: proc(t: ^pbt.T) -> pbt.Result {
	depth := pbt.draw(t, pbt.int_range(1, 4))
	named := pbt.draw(t, pbt.boolean())
	for level in 1 ..= 4 {
		pbt.cover(t, depth == level, 1, fmt.tprintf("depth-%d", level))
	}
	pbt.cover(t, named, 2, "named-constructors")
	pbt.cover(t, !named, 2, "positional-constructors")

	builder: strings.Builder
	strings.builder_init(&builder, t.value_allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `(package app)
(import strings "core:strings")

(defstruct Owned [value: string])
`)
	for level in 1 ..= depth {
		child_type := "Owned" if level == 1 else fmt.tprintf("Layer%d", level - 1)
		fmt.sbprintf(&builder, "(defstruct Layer%d [child: %s])\n", level, child_type)
	}
	strings.write_string(&builder, `
(defn clone-owned [value: string] -> Owned
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    (Owned :value result)))

`)
	fmt.sbprintf(&builder, "(defn delete-items [items: [dynamic]Layer%d]\n", depth)
	strings.write_string(&builder, "  (for [item items]\n    (delete item")
	for _ in 0 ..< depth {
		strings.write_string(&builder, ".child")
	}
	strings.write_string(&builder, ".value))\n  (delete items))\n\n(defn use [] -> int\n  (let [owned (clone-owned \"example\")\n")
	for level in 1 ..= depth {
		child_name := "owned" if level == 1 else fmt.tprintf("layer%d", level - 1)
		if named {
			fmt.sbprintf(&builder, "        layer%d (Layer%d :child %s)\n", level, level, child_name)
		} else {
			fmt.sbprintf(&builder, "        layer%d (Layer%d %s)\n", level, level, child_name)
		}
	}
	fmt.sbprintf(
		&builder,
		"        items (make [dynamic]Layer%d) :defer-with delete-items]\n    (append (addr items) layer%d)\n    (count items)))",
		depth,
		depth,
	)
	source := strings.to_string(builder)
	pbt.note(t, fmt.tprintf("depth=%d named=%t\n%s", depth, named, source))

	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated ownership program did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	if len(result.warnings) != 0 {
		return pbt.fail(fmt.tprintf("generated ownership program emitted warning: %s", result.warnings[0].message))
	}

	for level in 0 ..= depth {
		local_name := "owned" if level == 0 else fmt.tprintf("layer%d", level)
		cleanup: strings.Builder
		strings.builder_init(&cleanup, t.value_allocator)
		strings.write_string(&cleanup, "defer delete(")
		strings.write_string(&cleanup, local_name)
		for _ in 0 ..< level {
			strings.write_string(&cleanup, ".child")
		}
		strings.write_string(&cleanup, ".value)")
		cleanup_text := strings.to_string(cleanup)
		if strings.contains(result.output, cleanup_text) {
			strings.builder_destroy(&cleanup)
			return pbt.fail(fmt.tprintf("moved aggregate retained cleanup: %s", cleanup_text))
		}
		strings.builder_destroy(&cleanup)
	}
	return pbt.pass()
}

plain_data_aggregate_results_stay_ownership_certain :: proc(t: ^pbt.T) -> pbt.Result {
	field_count := pbt.draw(t, pbt.int_range(3, len(POD_FIELD_TYPES)))
	flow := pbt.draw(t, pbt.int_range(0, 2))
	named := pbt.draw(t, pbt.boolean())
	pbt.cover(t, flow == 0, 2, "early-return")
	pbt.cover(t, flow == 1, 2, "mutation")
	pbt.cover(t, flow == 2, 2, "branch-result")
	pbt.cover(t, named, 2, "named-constructor")
	pbt.cover(t, !named, 2, "positional-constructor")
	for count in 3 ..= len(POD_FIELD_TYPES) {
		pbt.cover(t, field_count == count, 1, fmt.tprintf("fields-%d", count))
	}

	builder: strings.Builder
	strings.builder_init(&builder, t.value_allocator)
	defer strings.builder_destroy(&builder)
	strings.write_string(&builder, `(package app)

(defenum Phase [unknown ready])
(defstruct Summary [`)
	for index in 0 ..< field_count {
		fmt.sbprintf(&builder, "f%d: %s ", index, POD_FIELD_TYPES[index])
	}
	strings.write_string(&builder, "])\n\n(defn summarize [flag: bool] -> Summary\n")
	switch flow {
	case 0:
		strings.write_string(&builder, "  (if flag\n    (return ")
		write_pod_constructor(&builder, field_count, named, false)
		strings.write_string(&builder, ")\n    (println \"fallback\"))\n  ")
		write_pod_constructor(&builder, field_count, named, true)
		strings.write_byte(&builder, ')')
	case 1:
		strings.write_string(&builder, "  (let [result ")
		write_pod_constructor(&builder, field_count, named, false)
		strings.write_string(&builder, "]\n    (set! result.f0 flag)\n    result))")
	case 2:
		strings.write_string(&builder, "  (if flag\n    ")
		write_pod_constructor(&builder, field_count, named, false)
		strings.write_string(&builder, "\n    ")
		write_pod_constructor(&builder, field_count, named, true)
		strings.write_string(&builder, "))")
	}
	strings.write_string(&builder, "\n\n(defn use [] -> int\n  (let [summary (summarize true)]\n    summary.f2))")
	source := strings.to_string(builder)
	pbt.note(t, fmt.tprintf("fields=%d flow=%d named=%t\n%s", field_count, flow, named, source))

	result, compile_error, ok := kvist.compile_source_with_map(source)
	if !ok {
		defer kvist.compile_error_delete(&compile_error)
		return pbt.fail(fmt.tprintf("generated plain-data program did not compile: %s", compile_error.message))
	}
	defer delete(result.output)
	defer kvist.source_map_slice_delete(result.source_map)
	defer kvist.compile_warning_slice_delete(result.warnings)
	for warning in result.warnings {
		if strings.contains(warning.message, "cannot be proven consistent across returns and mutations") {
			return pbt.fail(fmt.tprintf("plain-data result emitted ownership warning: %s", warning.message))
		}
	}

	lifetimes, lifetimes_error, lifetimes_ok := kvist.lifetimes_source(source)
	if !lifetimes_ok {
		defer kvist.compile_error_delete(&lifetimes_error)
		return pbt.fail(fmt.tprintf("lifetimes rejected generated plain-data program: %s", lifetimes_error.message))
	}
	defer delete(lifetimes)
	if strings.contains(lifetimes, "uncertain across returns or mutations") {
		return pbt.fail("plain-data result was marked uncertain across returns or mutations")
	}
	return pbt.pass()
}

write_pod_constructor :: proc(
	builder: ^strings.Builder,
	field_count: int,
	named: bool,
	alternate: bool,
) {
	values := POD_FIELD_VALUES[:]
	if alternate {
		values = POD_ALTERNATE_VALUES[:]
	}
	strings.write_string(builder, "(Summary")
	for index in 0 ..< field_count {
		if named {
			fmt.sbprintf(builder, " :f%d %s", index, values[index])
		} else {
			fmt.sbprintf(builder, " %s", values[index])
		}
	}
	strings.write_byte(builder, ')')
}
