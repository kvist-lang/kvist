package tests

import "core:fmt"
import "core:strings"
import "core:testing"
import kvist "../src/odin/kvist"

@(test)
managed_generic_specializations_reuse_concrete_bodies :: proc(t: ^testing.T) {
    source := `(package main)
(defn identity [value: $T] -> T (return value))
(defn repeat [callback: (fn [value: $T] -> T), initial: T] -> T
  (let [acc: T initial]
    (set! acc (callback acc)) acc))
(defn shared [value: Data] -> Data value)
(defn demo [source: Data] -> Data
  (let [first (identity source)
        second (identity source)]
    (repeat shared second)))`
    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok { testing.expect_value(t, err.message, ""); return }
    defer delete(output)
    definitions := 0
    for line in strings.split_lines(output, context.temp_allocator) {
        if strings.contains(line, "identity__kvist_managed_") && strings.contains(line, " :: proc(") {
            definitions += 1
        }
    }
    testing.expect_value(t, definitions, 1)
    testing.expect_value(t, strings.contains(output, "identity__kvist_managed_"), true)
    testing.expect_value(t, strings.contains(output, "repeat__kvist_managed_"), true)
    testing.expect_value(t, strings.contains(output, "return kvist_data_retain(value)"), true)
    testing.expect_value(t, strings.contains(output, "acc: Data = kvist_data_retain(initial)"), true)
    testing.expect_value(t, strings.contains(output, "kvist_data_move_assign(&(acc), callback(acc))"), true)
}

@(test)
managed_callback_types_survive_globals_and_indexed_aliases :: proc(t: ^testing.T) {
    source := `(package main)
(defn make-value [] -> Data (odin-call "kvist_data_make_text" .String "owned"))
(def maker make-value)
(defn demo []
  (let [makers: [1](fn [] -> Data) [make-value]
        alias (get makers 0)
        first (maker)
        second (alias)]
    (discard first) (discard second)))`
    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok { testing.expect_value(t, err.message, ""); return }
    defer delete(output)
    testing.expect_value(t, strings.contains(output, "first := maker()"), true)
    testing.expect_value(t, strings.contains(output, "second := alias()"), true)
    testing.expect_value(t, strings.contains(output, "})(&first, &kvist_owner_"), true)
    testing.expect_value(t, strings.contains(output, "})(&second, &kvist_owner_"), true)
    testing.expect_value(t, strings.contains(output, "kvist_data_retain(maker())"), false)
}

@(test)
managed_runtime_owned_helpers_do_not_retain_twice :: proc(t: ^testing.T) {
    source := `(package main)
(defn append-value [source: Data, value: Data] -> Data
  (odin-call "kvist_data_append" source value))
(defn remove-value [source: Data, path: Data] -> Data
  (odin-call "kvist_data_dissoc_in" source path))
(defn lift-value [source: string] -> Data
  (odin-call "kvist_data_lift_string" source))
(defn rest-value [source: Data] -> Data
  (odin-call "kvist_data_rest_from" source 1))`
    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok { testing.expect_value(t, err.message, ""); return }
    defer delete(output)
    for helper in ([]string{"append", "dissoc_in", "lift_string", "rest_from"}) {
        testing.expect_value(t, strings.contains(output, fmt.tprintf("return kvist_data_%s(", helper)), true)
        testing.expect_value(t, strings.contains(output, fmt.tprintf("return kvist_data_retain(kvist_data_%s(", helper)), false)
    }
}

@(test)
managed_conditions_release_arguments_inside_each_evaluation :: proc(t: ^testing.T) {
    source := `(package main)
(defn maker [] -> Data (odin-call "kvist_data_make_text" .String "owned"))
(defn pred [value: Data] -> bool true)
(defn demo [limit: int]
  (let [index 0]
    (while (and (< index limit) (pred (maker)))
      (inc! index))))`
    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok { testing.expect_value(t, err.message, ""); return }
    defer delete(output)
    loop_start := strings.index(output, "    for (")
    testing.expect(t, loop_start >= 0)
    if loop_start >= 0 {
        loop_body := output[loop_start:]
        testing.expect_value(t, strings.contains(loop_body, "&& ((proc("), true)
        testing.expect_value(t, strings.contains(loop_body, " := maker()"), true)
        testing.expect_value(t, strings.contains(loop_body, "defer kvist_data_release(kvist_thread_"), true)
    }
}

@(test)
managed_generics_support_explicit_type_and_keyword_arguments :: proc(t: ^testing.T) {
    source := `(package main)
(defn typed-identity [$T: typeid, value: T] -> T
  (let [copy: T value] copy))
(defn keyword-identity [value: $T, enabled?: bool :default true] -> T value)
(defn demo [source: Data] -> Data
  (let [first (typed-identity Data source)]
    (keyword-identity :value first :enabled? true)))`
    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok { testing.expect_value(t, err.message, ""); return }
    defer delete(output)
    testing.expect_value(t, strings.contains(output, "typed_identity__kvist_managed_"), true)
    testing.expect_value(t, strings.contains(output, "keyword_identity__kvist_managed_"), true)
    testing.expect_value(t, strings.contains(output, "copy: Data = kvist_data_retain(value)"), true)
    testing.expect_value(t, strings.contains(output, "value = first, enabled_p = true"), true)
}

@(test)
scoped_owned_conditions_preserve_following_source_locations :: proc(t: ^testing.T) {
    source := `(package main)
(defn maker [] -> Data (odin-call "kvist_data_make_text" .String "owned"))
(defn pred [value: Data] -> bool true)
(defn main []
  (while (pred (maker)) (break))
  (println "after"))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok { testing.expect_value(t, err.message, ""); return }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)
    offset := strings.index(result.output, "fmt.println(\"after\")")
    testing.expect(t, offset >= 0)
    if offset < 0 { return }
    line := strings.count(result.output[:offset], "\n")+1
    entry, found := kvist.source_map_entry_for_generated_line(result.source_map[:], line)
    testing.expect(t, found)
    if found {
        testing.expect_value(t, strings.contains(source[entry.source_span.start:entry.source_span.end], "\"after\""), true)
    }
}
