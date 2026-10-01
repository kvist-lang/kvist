package tests

import "base:runtime"
import fmt "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import kvist "../src/odin/kvist"

@(test)
owned_native_multi_result_propagates_through_local_let_wrapper :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defn clone-text-result [source: string] -> [value: string, ok: bool]
  (assert (> (count source) 0))
  (let [[cloned error] (strings.clone source)]
    (assert (= error nil))
    (return cloned true)))

(defn use [] -> int
  (let [[value ok] (clone-text-result "hello")]
    (assert ok)
    (count value)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(
            result.output,
            "value, ok := clone_text_result(\"hello\")\n    defer delete(value)",
        ),
        true,
    )
}

@(test)
owned_native_call_propagates_from_direct_multi_return :: proc(t: ^testing.T) {
    source := `(package app)
(import strings "core:strings")

(defn clone-text-result [source: string] -> [value: string, ok: bool]
  (do
    (assert (> (count source) 0))
    (return (strings.clone source) true)))

(defn use [] -> int
  (let [[value ok] (clone-text-result "hello")]
    (assert ok)
    (count value)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(
            result.output,
            "value, ok := clone_text_result(\"hello\")\n    defer delete(value)",
        ),
        true,
    )
}

@(test)
owned_optional_error_call_propagates_from_single_binding :: proc(t: ^testing.T) {
    source := `(package app)
(import strings "core:strings")

(defn clone-text-result [source: string] -> [value: string, ok: bool]
  (let [cloned (strings.clone source)]
    (return cloned true)))

(defn use [] -> int
  (let [[value ok] (clone-text-result "hello")]
    (assert ok)
    (count value)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(
            result.output,
            "value, ok := clone_text_result(\"hello\")\n    defer delete(value)",
        ),
        true,
    )
}

@(test)
conditional_owned_multi_result_remaps_sibling_after_reordering :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defn replace-result [source: string old: string new: string]
  -> [allocated?: bool, result: string]
  (let [[value allocated?] (strings.replace source old new -1)]
    (return allocated? value)))

(defn use [] -> int
  (let [[allocated? value] (replace-result "hello" "e" "a")]
    (assert allocated?)
    (count value)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "if allocated_p {"), true)
    testing.expect_value(t, strings.contains(result.output, "delete(value)"), true)
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(value)"),
        false,
    )
}

@(test)
owned_result_prefix_inference_rejects_an_early_return :: proc(t: ^testing.T) {
    source := `(package app)
(import strings "core:strings")

(defn maybe-clone [source: string borrow?: bool] -> [value: string, owned?: bool]
  (when borrow?
    (return source false))
  (let [[cloned error] (strings.clone source)]
    (assert (= error nil))
    (return cloned true)))

(defn use [] -> int
  (let [[value owned?] (maybe-clone "hello" false)]
    (assert owned?)
    (count value)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    // One branch borrows while the other owns. Without an explicit local
    // contract, inferring cleanup from the tail alone would be a bad free.
    testing.expect_value(t, strings.contains(result.output, "delete(value)"), false)
}

@(test)
owned_result_nested_prefix_inference_rejects_an_early_return :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defn maybe-replace [source: string borrow?: bool]
  -> [allocated?: bool, result: string]
  (let [[replaced did-allocate?] (strings.replace source "e" "a" -1)]
    (when borrow?
      (return true source))
    (return did-allocate? replaced)))

(defn use [] -> int
  (let [[allocated? value] (maybe-replace "hello" true)]
    (assert allocated?)
    (count value)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "delete(value)"), false)
}

@(test)
conditional_owned_result_rejects_a_mutated_activation_sibling :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defn replace-inverted [source: string old: string new: string]
  -> [allocated?: bool, result: string]
  (let [[value did-allocate?] (strings.replace source old new -1)]
    (set! did-allocate? (not did-allocate?))
    (return did-allocate? value)))

(defn replace-toggled [source: string old: string new: string]
  -> [allocated?: bool, result: string]
  (let [[value did-allocate?] (strings.replace source old new -1)]
    (toggle! did-allocate?)
    (return did-allocate? value)))

(defn invert-bool! [value: ^bool]
  (toggle! value^))

(defn replace-pointer-inverted [source: string old: string new: string]
  -> [allocated?: bool, result: string]
  (let [[value did-allocate?] (strings.replace source old new -1)]
    (invert-bool! (addr did-allocate?))
    (return did-allocate? value)))

(defn use [] -> int
  (let [[allocated? value] (replace-inverted "hello" "z" "x")
        [toggle-allocated? toggle-value] (replace-toggled "hello" "z" "x")
        [pointer-allocated? pointer-value]
          (replace-pointer-inverted "hello" "z" "x")]
    (assert allocated?)
    (assert toggle-allocated?)
    (assert pointer-allocated?)
    (+ (count value) (count toggle-value) (count pointer-value))))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "delete(value)"), false)
    testing.expect_value(
        t,
        strings.contains(result.output, "delete(toggle_value)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "delete(pointer_value)"),
        false,
    )
}

@(test)
discarded_owned_results_are_materialized_and_cleaned_immediately :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defstruct Box [text: string])
(defunion Choice [text: string number: int])

(defn clone-pair [left: string right: string]
  -> [left-result: string, right-result: string]
  (return (strings.clone left) (strings.clone right)))

(defn make-box [] -> [box: Box, ok: bool]
  (return (Box :text (strings.clone "box")) true))

(defn make-choice [] -> [choice: Choice, ok: bool]
  (return (Choice :text (strings.clone "choice")) true))

(defn use [] -> int
  (discard (strings.clone "expression"))
  (discard (clone-pair "discard-left" "discard-right"))
  (discard (strings.replace "hello" "e" "a" -1))
  (make-box)
  (discard (make-box))
  (make-choice)
  (discard (make-choice))
  (let [_ (strings.clone "simple")
        [_ right] (clone-pair "left" "right")
        [_ allocated?] (strings.replace "hello" "e" "a" -1)
        [_ _] (strings.replace "hello" "e" "a" -1)
        [_ box-ok] (make-box)
        [box retained-box-ok] (make-box)
        [_ choice-ok] (make-choice)
        [choice retained-choice-ok] (make-choice)]
    (assert allocated?)
    (assert box-ok)
    (assert retained-box-ok)
    (assert choice-ok)
    (assert retained-choice-ok)
    (+ (count right)
       (count box.text)
       (count (case choice (string value) value "")))))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_thread_"), true)
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(kvist_thread_"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "_ = strings.clone"),
        false,
    )
    testing.expect_value(t, strings.contains(result.output, "_, right :="), false)
    testing.expect_value(t, strings.contains(result.output, ".text)"), true)
    testing.expect_value(t, strings.contains(result.output, "defer delete(box.text)"), true)
    testing.expect_value(t, strings.contains(result.output, "#partial switch"), true)
    testing.expect_value(t, strings.contains(result.output, "case string:"), true)
}

@(test)
owned_managed_multi_result_moves_into_returned_struct :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import data "kvist:data")

(defstruct Snapshot [comments: Data])

(defn pull [] -> [comments: Data, ok: bool]
  (return [{:id "comment-1"} {:id "comment-2"}] true))

(defn load [] -> Snapshot
  (let [[comments ok] (pull)]
    (when (not ok)
      (data.release comments)
      (return (Snapshot :comments nil)))
    (Snapshot :comments comments)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "Snapshot{comments ="), true)
    testing.expect_value(
        t,
        strings.contains(
            result.output,
            "return Snapshot{comments = kvist_data_retain(comments)}",
        ),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "kvist_data_release(kvist_place^)"),
        true,
    )
}

@(test)
data_stored_in_data_aggregate_is_cleaned_after_the_aggregate_retains_it :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import data "kvist:data")

(defn section [] -> Data
  (let [content: Data [:div "content"]
        result: Data [:section content]]
    result))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(result.output, "kvist_data_release(kvist_place^)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "(&content,"),
        true,
    )
}

@(test)
explicit_aggregate_destructor_covers_inferred_owned_fields :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import fmt "core:fmt")

(defstruct State [manual: string automatic: string])

(defn make-state [] -> State
  (State
    :manual (fmt.aprintf "manual=%d" 42)
    :automatic (fmt.aprintf "automatic=%d" 42)))

(defn delete-state! [state: ^State]
  (delete state^.manual))

(defn deferred-cleanup [] -> int
  (let [deferred-state (make-state)]
    (defer (delete-state! (addr deferred-state)))
    (count deferred-state.manual)))

(defn direct-cleanup []
  (let [direct-state (make-state)]
    (delete-state! (addr direct-state))))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(deferred_state.manual)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(direct_state.manual)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(deferred_state.automatic)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(direct_state.automatic)"),
        true,
    )
}

@(test)
path_dependent_aggregate_destructor_takes_precedence_and_warns :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import fmt "core:fmt")

(defstruct State [manual: string automatic: string])

(defn make-state [] -> State
  (State
    :manual (fmt.aprintf "manual=%d" 42)
    :automatic (fmt.aprintf "automatic=%d" 42)))

(defn maybe-delete-state! [state: ^State cleanup?: bool]
  (if cleanup?
    (delete state^.manual)
    nil))

(defn use [] -> int
  (let [state (make-state)]
    (defer (maybe-delete-state! (addr state) true))
    (count state.manual)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(state.manual)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(state.automatic)"),
        true,
    )
    testing.expect_value(t, len(result.warnings), 1)
    if len(result.warnings) == 1 {
        testing.expect_value(
            t,
            result.warnings[0].message,
            "explicit cleanup of aggregate field `state.manual` is path-dependent; automatic cleanup was disabled to avoid double-free, so ensure the cleanup procedure releases the field on every return path",
        )
        testing.expect_value(
            t,
            result.warnings[0].code,
            kvist.Compile_Warning_Code.Ownership_Automatic_Cleanup_Skipped,
        )
        testing.expect_value(
            t,
            result.warnings[0].confidence,
            kvist.Compile_Warning_Confidence.Conservative,
        )
    }
}

@(test)
owned_structs_returned_inside_fixed_array_transfer_their_fields :: proc(t: ^testing.T) {
    source := `(package app)

(defstruct Box [items: [dynamic]int])

(defn make-box [value: int] -> Box
  (Box :items ([dynamic]int [value])))

(defn make-pair [] -> [2]Box
  (let [left (make-box 1)
        right (make-box 2)]
    [left right]))`
    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "return [2]Box{left, right}"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(left.items)"), false)
    testing.expect_value(t, strings.contains(output, "defer delete(right.items)"), false)
}

@(test)
nested_owned_struct_stored_in_managed_struct_transfers_the_source :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defstruct Optional-String [value: string present?: bool])
(defstruct Link [observed-name: Optional-String])

(defn copy-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn clone-optional-string [value: Optional-String] -> Optional-String
  (Optional-String
    :value (copy-string value.value)
    :present? value.present?))

(defn delete-links [links: [dynamic]Link]
  (for [link links]
    (delete link.observed-name.value))
  (delete links))

(defn use [] -> int
  (let [source (Optional-String :value "example" :present? true)
        links (make [dynamic]Link) :defer-with delete-links
        observed-name (clone-optional-string source)
        link (Link :observed-name observed-name)]
    (append (addr links) link)
    (count links)))`
    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(
        t,
        strings.contains(output, "defer delete(observed_name.value)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(output, "Link{observed_name = observed_name}"),
        true,
    )
}

@(test)
pod_struct_result_does_not_report_uncertain_owned_fields :: proc(
    t: ^testing.T,
) {
    source := `(package app)

(defenum Phase [unknown ready])
(defstruct Summary [ok?: bool phase: Phase count: int])

(defn summarize [ready?: bool] -> Summary
  (if ready?
    (return (Summary :ok? true :phase Phase.ready :count 1))
    (println "not ready"))
  (Summary :ok? false :phase Phase.unknown :count 0))

(defn use [] -> int
  (let [summary (summarize true)]
    summary.count))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    lifetimes, lifetimes_err, lifetimes_ok := kvist.lifetimes_source(source)
    testing.expect_value(t, lifetimes_ok, true)
    if lifetimes_ok {
        defer delete(lifetimes)
        testing.expect_value(
            t,
            strings.contains(
                lifetimes,
                "uncertain across returns or mutations",
            ),
            false,
        )
    } else {
        defer kvist.compile_error_delete(&lifetimes_err)
        testing.expect_value(t, lifetimes_err.message, "")
    }
}

@(test)
owned_parameter_fields_transfer_to_scalar_results :: proc(t: ^testing.T) {
    source := `(package app)

(defstruct Pair [left: string right: string])
(defstruct Inner [text: string])
(defstruct Outer [inner: Inner])

(defn make-pair [] -> Pair
  (Pair :left (str "left") :right (str "right")))

(defn take-left [value: Pair] -> string
  (delete value.right)
  value.left)

(defn take-nested [value: Outer] -> string
  value.inner.text)

(defn take-left-through-alias [value: Pair] -> string
  (let [result value.left]
    (delete value.right)
    result))

(defn delete-text [value: string]
  (delete value))

(defn use [] -> int
  (let [first (make-pair)
        first-result (take-left first) :defer-with delete-text
        nested (Outer :inner (Inner :text (str "nested")))
        nested-result (take-nested nested) :defer-with delete-text
        aliased (make-pair)
        alias-result (take-left-through-alias aliased) :defer-with delete-text]
    (+ (count first-result) (count nested-result) (count alias-result))))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(first.left)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(first.right)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(nested.inner.text)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(aliased.left)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(aliased.right)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete_text(first_result)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete_text(nested_result)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete_text(alias_result)"),
        true,
    )
}

@(test)
early_return_does_not_claim_full_parameter_field_transfer :: proc(
    t: ^testing.T,
) {
    source := `(package app)

(defstruct Pair [left: string right: string])

(defn make-pair [] -> Pair
  (Pair :left (str "left") :right (str "right")))

(defn take-early [value: Pair left?: bool] -> string
  (if left?
    (return value.left))
  (delete value.left)
  value.right)

(defn use [left?: bool] -> int
  (let [value (make-pair)
        result (take-early value left?)]
    (count result)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    result_uncertain := false
    field_cleanup_conditional := false
    for warning in result.warnings {
        if strings.contains(
            warning.message,
            "ownership of result from take-early differs across return paths",
        ) {
            result_uncertain = true
        }
        if strings.contains(
            warning.message,
            "explicit cleanup of aggregate field `value.left` is path-dependent",
        ) {
            field_cleanup_conditional = true
        }
    }
    testing.expect_value(t, result_uncertain, true)
    testing.expect_value(t, field_cleanup_conditional, true)

    lifetimes, lifetimes_err, lifetimes_ok := kvist.lifetimes_source(source)
    testing.expect_value(t, lifetimes_ok, true)
    if lifetimes_ok {
        defer delete(lifetimes)
        testing.expect_value(
            t,
            strings.contains(lifetimes, "take-early"),
            true,
        )
        testing.expect_value(
            t,
            strings.contains(
                lifetimes,
                "result: uncertain across return paths; automatic caller cleanup is not inserted",
            ),
            true,
        )
    } else {
        defer kvist.compile_error_delete(&lifetimes_err)
        testing.expect_value(t, lifetimes_err.message, "")
    }
}

@(test)
conditional_struct_construction_transfers_owned_fields_on_either_path :: proc(
    t: ^testing.T,
) {
    source := `(package app)
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

(defn use [flag: bool] -> int
  (let [left (clone-string "left")
        right (clone-string "right")
        payload (if flag
          (Payload :left left :right right :marker 1)
          (Payload :left left :right right :marker 2))
        items (make [dynamic]Payload) :defer-with delete-items]
    (append (addr items) payload)
    (count items)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "defer delete(left)"), false)
    testing.expect_value(t, strings.contains(result.output, "defer delete(right)"), false)
    testing.expect_value(t, strings.contains(result.output, "defer delete(payload.left)"), false)
    testing.expect_value(t, strings.contains(result.output, "defer delete(payload.right)"), false)
}

@(test)
duplicate_nested_aggregate_and_fixed_array_transfers_are_diagnosed :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defstruct Leaf [text: string])
(defstruct Outer [leaf: Leaf])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn duplicate-aggregate [] -> int
  (let [owned (clone-string "aggregate")
        leaf (Leaf :text owned)
        first (Outer :leaf leaf)
        second (Outer :leaf leaf)]
    (+ (count first.leaf.text) (count second.leaf.text))))

(defn duplicate-fixed-array [] -> int
  (let [owned (clone-string "array")
        leaf (Leaf :text owned)
        first ([1]Leaf [leaf])
        second ([1]Leaf [leaf])]
    (+ (count first[0].text) (count second[0].text))))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 2)
    for warning in result.warnings {
        testing.expect_value(
            t,
            warning.code,
            kvist.Compile_Warning_Code.Ownership_Use_After_Transfer,
        )
        testing.expect_value(
            t,
            warning.confidence,
            kvist.Compile_Warning_Confidence.Definite,
        )
    }
}

@(test)
owned_argument_forwarded_into_struct_result_is_not_cleaned_at_call_site :: proc(
    t: ^testing.T,
) {
    source := `(package app)

(defstruct Projection [values: [dynamic]string])

(defn projection [values: [dynamic]string] -> Projection
  (Projection :values values))

(defn make-projection [] -> Projection
  (let [values (make [dynamic]string)]
    (projection values)))`
    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "return projection(values)"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(values)"), false)
}

@(test)
owned_local_consumed_through_address_is_not_cleaned_again :: proc(
    t: ^testing.T,
) {
    source := `(package app)

(defn consume-values! [values: ^[dynamic]string]
  (delete values^))

(defn use [] -> int
  (let [values (make [dynamic]string)]
    (consume-values! (addr values))
    0))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(result.output, "consume_values_bang(&values)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(values)"),
        false,
    )
}

@(test)
ownership_contract_registry_is_well_formed :: proc(t: ^testing.T) {
    message, ok := kvist.ownership_contracts_validate()
    if !ok {
        defer delete(message)
    }
    testing.expect_value(t, ok, true)
    testing.expect_value(t, message, "")
}

@(test)
ownership_ir_classifies_straight_line_and_moved_cleanup :: proc(t: ^testing.T) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 2,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    block := kvist.ownership_ir_add_block(&graph)
    testing.expect_value(t, block, 0)
    testing.expect_value(
        t,
        kvist.ownership_ir_add_event(&graph, block, {kind = .Acquire, place = 0}),
        true,
    )
    testing.expect_value(
        t,
        kvist.ownership_ir_add_event(&graph, block, {kind = .Move, place = 0, target = 1}),
        true,
    )
    analysis := kvist.ownership_ir_analyze(graph)
    defer kvist.ownership_ir_analysis_delete(&analysis)

    testing.expect_value(t, analysis.valid, true)
    testing.expect_value(t, analysis.converged, true)
    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_need(analysis.blocks[0].exit[0]),
        kvist.Ownership_IR_Cleanup_Need.None,
    )
    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_need(analysis.blocks[0].exit[1]),
        kvist.Ownership_IR_Cleanup_Need.Always,
    )
}

@(test)
ownership_ir_classifies_external_store_cleanup :: proc(t: ^testing.T) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 1,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    block := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Acquire, place = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Store, place = 0, target = -1},
    )
    analysis := kvist.ownership_ir_analyze(graph)
    defer kvist.ownership_ir_analysis_delete(&analysis)

    testing.expect_value(t, analysis.valid, true)
    testing.expect_value(t, analysis.converged, true)
    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_need(analysis.blocks[0].exit[0]),
        kvist.Ownership_IR_Cleanup_Need.None,
    )
}

@(test)
ownership_ir_classifies_branch_cleanup :: proc(t: ^testing.T) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 1,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    entry := kvist.ownership_ir_add_block(&graph)
    destroyed := kvist.ownership_ir_add_block(&graph)
    live := kvist.ownership_ir_add_block(&graph)
    joined := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(&graph, entry, {kind = .Acquire, place = 0})
    kvist.ownership_ir_add_event(&graph, destroyed, {kind = .Destroy, place = 0})
    kvist.ownership_ir_add_successor(&graph, entry, destroyed)
    kvist.ownership_ir_add_successor(&graph, entry, live)
    kvist.ownership_ir_add_successor(&graph, destroyed, joined)
    kvist.ownership_ir_add_successor(&graph, live, joined)
    analysis := kvist.ownership_ir_analyze(graph)
    defer kvist.ownership_ir_analysis_delete(&analysis)

    testing.expect_value(t, analysis.valid, true)
    testing.expect_value(t, analysis.converged, true)
    testing.expect_value(t, analysis.blocks[3].reachable, true)
    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_need(analysis.blocks[3].entry[0]),
        kvist.Ownership_IR_Cleanup_Need.Conditional,
    )
}

@(test)
ownership_ir_borrow_lattice_distinguishes_may_and_must_across_branches :: proc(t: ^testing.T) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 4,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    entry := kvist.ownership_ir_add_block(&graph)
    left := kvist.ownership_ir_add_block(&graph)
    right := kvist.ownership_ir_add_block(&graph)
    joined := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(
        &graph,
        left,
        {kind = .Borrow_Assign, place = 2, target = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        left,
        {kind = .Borrow_Assign, place = 3, target = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        right,
        {kind = .Borrow_Assign, place = 2, target = 1},
    )
    kvist.ownership_ir_add_successor(&graph, entry, left)
    kvist.ownership_ir_add_successor(&graph, entry, right)
    kvist.ownership_ir_add_successor(&graph, left, joined)
    kvist.ownership_ir_add_successor(&graph, right, joined)
    analysis := kvist.ownership_ir_analyze_borrows(graph)
    defer kvist.ownership_ir_borrow_analysis_delete(&analysis)

    testing.expect_value(t, analysis.valid, true)
    testing.expect_value(t, analysis.converged, true)
    testing.expect_value(t, analysis.blocks[joined].reachable, true)
    testing.expect_value(
        t,
        analysis.blocks[joined].entry[2],
        kvist.Ownership_IR_Borrow_Fact{
            may_borrowed = true,
            must_borrowed = true,
        },
    )
    testing.expect_value(
        t,
        analysis.blocks[joined].entry[3],
        kvist.Ownership_IR_Borrow_Fact{
            may_borrowed = true,
            must_borrowed = false,
        },
    )
    testing.expect_value(
        t,
        analysis.blocks[joined].entry_owners[2*graph.place_count+0],
        true,
    )
    testing.expect_value(
        t,
        analysis.blocks[joined].entry_owners[2*graph.place_count+1],
        true,
    )
}

@(test)
ownership_ir_borrow_lattice_tracks_destroyed_owners_across_branches :: proc(t: ^testing.T) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 5,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    entry := kvist.ownership_ir_add_block(&graph)
    left := kvist.ownership_ir_add_block(&graph)
    right := kvist.ownership_ir_add_block(&graph)
    joined := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(
        &graph,
        left,
        {kind = .Borrow_Assign, place = 2, target = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        left,
        {kind = .Borrow_Assign, place = 3, target = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        left,
        {kind = .Destroy, place = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        right,
        {kind = .Borrow_Assign, place = 2, target = 1},
    )
    kvist.ownership_ir_add_event(
        &graph,
        right,
        {kind = .Borrow_Assign, place = 3, target = 4},
    )
    kvist.ownership_ir_add_event(
        &graph,
        right,
        {kind = .Destroy, place = 1},
    )
    kvist.ownership_ir_add_successor(&graph, entry, left)
    kvist.ownership_ir_add_successor(&graph, entry, right)
    kvist.ownership_ir_add_successor(&graph, left, joined)
    kvist.ownership_ir_add_successor(&graph, right, joined)
    analysis := kvist.ownership_ir_analyze_borrows(graph)
    defer kvist.ownership_ir_borrow_analysis_delete(&analysis)

    testing.expect_value(t, analysis.valid, true)
    testing.expect_value(t, analysis.converged, true)
    testing.expect_value(
        t,
        analysis.blocks[joined].entry_invalid[2],
        kvist.Ownership_IR_Borrow_Invalid_Fact{
            may_invalid = true,
            must_invalid = true,
        },
    )
    testing.expect_value(
        t,
        analysis.blocks[joined].entry_invalid[3],
        kvist.Ownership_IR_Borrow_Invalid_Fact{
            may_invalid = true,
            must_invalid = false,
        },
    )
    testing.expect_value(
        t,
        analysis.blocks[joined].entry_invalid_owners[2*graph.place_count+0],
        true,
    )
    testing.expect_value(
        t,
        analysis.blocks[joined].entry_invalid_owners[2*graph.place_count+1],
        true,
    )
    testing.expect_value(
        t,
        analysis.blocks[joined].entry_owners[3*graph.place_count+4],
        true,
    )
}

@(test)
ownership_ir_distinguishes_scheduled_cleanup :: proc(t: ^testing.T) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 2,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    block := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(&graph, block, {kind = .Acquire, place = 0})
    kvist.ownership_ir_add_event(&graph, block, {kind = .Acquire, place = 1})
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Schedule_Destroy, place = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Schedule_Destroy, place = 1, conditional = true},
    )
    analysis := kvist.ownership_ir_analyze(graph)
    defer kvist.ownership_ir_analysis_delete(&analysis)

    testing.expect_value(t, analysis.valid, true)
    testing.expect_value(t, analysis.converged, true)
    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_need(analysis.blocks[0].exit[0]),
        kvist.Ownership_IR_Cleanup_Need.None,
    )
    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_need(analysis.blocks[0].exit[1]),
        kvist.Ownership_IR_Cleanup_Need.Conditional,
    )
}

@(test)
ownership_ir_cleanup_plan_is_per_exit :: proc(t: ^testing.T) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 1,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    entry := kvist.ownership_ir_add_block(&graph)
    returned := kvist.ownership_ir_add_block(&graph)
    live := kvist.ownership_ir_add_block(&graph)
    returned_boundary := kvist.ownership_ir_add_block(&graph)
    live_boundary := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(&graph, entry, {kind = .Acquire, place = 0})
    kvist.ownership_ir_add_event(&graph, returned, {kind = .Return, place = 0})
    kvist.ownership_ir_add_successor(&graph, entry, returned)
    kvist.ownership_ir_add_successor(&graph, entry, live)
    kvist.ownership_ir_add_successor(&graph, returned, returned_boundary)
    kvist.ownership_ir_add_successor(&graph, live, live_boundary)

    scope_exits: [dynamic]kvist.Ownership_IR_Exit
    defer delete(scope_exits)
    append(
        &scope_exits,
        kvist.Ownership_IR_Exit{kind = .Return, block = returned_boundary},
        kvist.Ownership_IR_Exit{kind = .Fallthrough, block = live_boundary},
    )
    places: [dynamic]kvist.Ownership_IR_Shadow_Place
    defer delete(places)
    append(&places, kvist.Ownership_IR_Shadow_Place{
        place = 0,
        name = "data",
        cleanup_head = "delete",
        scope_exits = scope_exits,
    })
    shadow := kvist.Ownership_IR_Shadow_Proc{
        graph = graph,
        places = places,
    }
    analysis := kvist.ownership_ir_analyze(graph)
    defer kvist.ownership_ir_analysis_delete(&analysis)
    plan := kvist.ownership_ir_build_cleanup_plan(shadow, analysis)
    defer kvist.ownership_ir_cleanup_plan_delete(&plan)

    testing.expect_value(t, plan.valid, true)
    testing.expect_value(t, len(plan.actions), 2)
    if len(plan.actions) == 2 {
        testing.expect_value(t, plan.actions[0].block, returned_boundary)
        testing.expect_value(t, plan.actions[0].exit_kind, kvist.Ownership_IR_Exit_Kind.Return)
        testing.expect_value(t, plan.actions[0].need, kvist.Ownership_IR_Cleanup_Need.None)
        testing.expect_value(t, plan.actions[1].block, live_boundary)
        testing.expect_value(t, plan.actions[1].exit_kind, kvist.Ownership_IR_Exit_Kind.Fallthrough)
        testing.expect_value(t, plan.actions[1].need, kvist.Ownership_IR_Cleanup_Need.Always)
    }
    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_plan_need(plan, 0),
        kvist.Ownership_IR_Cleanup_Need.Conditional,
    )
    placement, placement_need := kvist.ownership_ir_cleanup_plan_placement(
        plan,
        0,
    )
    testing.expect_value(
        t,
        placement,
        kvist.Ownership_IR_Cleanup_Placement.Per_Exit,
    )
    testing.expect_value(
        t,
        placement_need,
        kvist.Ownership_IR_Cleanup_Need.Conditional,
    )

    kvist.ownership_ir_add_event(
        &graph,
        live_boundary,
        {kind = .Borrow, place = 0},
    )
    invalid_plan := kvist.ownership_ir_build_cleanup_plan(shadow, analysis)
    defer kvist.ownership_ir_cleanup_plan_delete(&invalid_plan)
    testing.expect_value(t, invalid_plan.valid, false)
}

@(test)
ownership_ir_cleanup_plan_exposes_structured_diagnostics :: proc(
    t: ^testing.T,
) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 1,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    entry := kvist.ownership_ir_add_block(&graph)
    boundary := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(
        &graph,
        entry,
        {kind = .Acquire, place = 0},
    )
    kvist.ownership_ir_add_successor(&graph, entry, boundary)

    scope_exits: [dynamic]kvist.Ownership_IR_Exit
    defer delete(scope_exits)
    append(
        &scope_exits,
        kvist.Ownership_IR_Exit{
            kind = .Fallthrough,
            block = boundary,
        },
    )
    places: [dynamic]kvist.Ownership_IR_Shadow_Place
    defer delete(places)
    append(&places, kvist.Ownership_IR_Shadow_Place{
        place = 0,
        name = "data",
        cleanup_head = "delete",
        cleanup_skip_reason = .Captured_By_Closure,
        scope_exits = scope_exits,
    })
    candidates: [dynamic]kvist.Ownership_IR_Diagnostic_Fact
    defer delete(candidates)
    append(&candidates, kvist.Ownership_IR_Diagnostic_Fact{
        kind = .Aggregate_Result_Fields_Uncertain,
        subject = "maybe-owned",
    })
    shadow := kvist.Ownership_IR_Shadow_Proc{
        graph = graph,
        places = places,
        diagnostic_candidates = candidates,
    }
    analysis := kvist.ownership_ir_analyze(graph)
    defer kvist.ownership_ir_analysis_delete(&analysis)
    plan := kvist.ownership_ir_build_cleanup_plan(shadow, analysis)
    defer kvist.ownership_ir_cleanup_plan_delete(&plan)

    testing.expect_value(t, plan.valid, true)
    testing.expect_value(t, len(plan.diagnostics), 2)
    if len(plan.diagnostics) == 2 {
        testing.expect_value(
            t,
            plan.diagnostics[0].kind,
            kvist.Ownership_IR_Diagnostic_Kind.Aggregate_Result_Fields_Uncertain,
        )
        testing.expect_value(t, plan.diagnostics[0].subject, "maybe-owned")
        testing.expect_value(
            t,
            plan.diagnostics[1].kind,
            kvist.Ownership_IR_Diagnostic_Kind.Automatic_Cleanup_Skipped,
        )
        testing.expect_value(
            t,
            plan.diagnostics[1].reason,
            kvist.Ownership_IR_Cleanup_Skip_Reason.Captured_By_Closure,
        )
        testing.expect_value(t, plan.diagnostics[1].subject, "data")
    }
}

@(test)
ownership_ir_converges_through_loop :: proc(t: ^testing.T) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 1,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    entry := kvist.ownership_ir_add_block(&graph)
    loop := kvist.ownership_ir_add_block(&graph)
    exit := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(&graph, entry, {kind = .Acquire, place = 0})
    kvist.ownership_ir_add_event(&graph, loop, {kind = .Borrow, place = 0})
    kvist.ownership_ir_add_successor(&graph, entry, loop)
    kvist.ownership_ir_add_successor(&graph, loop, loop)
    kvist.ownership_ir_add_successor(&graph, loop, exit)
    analysis := kvist.ownership_ir_analyze(graph)
    defer kvist.ownership_ir_analysis_delete(&analysis)

    testing.expect_value(t, analysis.valid, true)
    testing.expect_value(t, analysis.converged, true)
    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_need(analysis.blocks[2].entry[0]),
        kvist.Ownership_IR_Cleanup_Need.Always,
    )
}

@(test)
ownership_ir_value_liveness_keeps_scheduled_cleanup_usable :: proc(
    t: ^testing.T,
) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 1,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    block := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Acquire, place = 0, conditional = true},
    )
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Schedule_Destroy, place = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Borrow, place = 0},
    )

    cleanup := kvist.ownership_ir_analyze(graph)
    defer kvist.ownership_ir_analysis_delete(&cleanup)
    values := kvist.ownership_ir_analyze_value_liveness(graph)
    defer kvist.ownership_ir_analysis_delete(&values)

    testing.expect_value(t, cleanup.blocks[block].exit[0].may_live, false)
    testing.expect_value(t, values.blocks[block].exit[0].may_live, true)
    testing.expect_value(t, values.blocks[block].exit[0].must_live, true)
}

@(test)
ownership_ir_scheduled_cleanup_covers_later_reassignment :: proc(t: ^testing.T) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 1,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    block := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Acquire, place = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Schedule_Destroy, place = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Reassign, place = 0},
    )

    cleanup := kvist.ownership_ir_analyze(graph)
    defer kvist.ownership_ir_analysis_delete(&cleanup)
    values := kvist.ownership_ir_analyze_value_liveness(graph)
    defer kvist.ownership_ir_analysis_delete(&values)

    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_need(cleanup.blocks[block].exit[0]),
        kvist.Ownership_IR_Cleanup_Need.None,
    )
    testing.expect_value(t, values.blocks[block].exit[0].may_live, true)
    testing.expect_value(t, values.blocks[block].exit[0].must_live, true)
}

@(test)
ownership_analysis_recognizes_nonreturning_wrapper_control_flow :: proc(
    t: ^testing.T,
) {
    source := `(package main)
(import data "kvist:data")
(import os "core:os")

(defn stop! []
  (os.exit 1))

(defn use [stop?: bool] -> int
  (let [value: Data []]
    (defer (data.release value))
    (let [flag
            (if stop?
              (do
                (data.release value)
                (stop!)
                false)
              true)]
      (discard flag))
    (data.count value)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
}

@(test)
ownership_ir_diagnoses_discarded_but_not_destroyed_transients :: proc(
    t: ^testing.T,
) {
    graph := kvist.Ownership_IR_Proc{
        place_count = 2,
        entry = 0,
    }
    defer kvist.ownership_ir_proc_delete(&graph)
    block := kvist.ownership_ir_add_block(&graph)
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Acquire, place = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Discard, place = 0},
    )
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Acquire, place = 1},
    )
    kvist.ownership_ir_add_event(
        &graph,
        block,
        {kind = .Destroy, place = 1},
    )

    places: [dynamic]kvist.Ownership_IR_Shadow_Place
    defer delete(places)
    append(
        &places,
        kvist.Ownership_IR_Shadow_Place{
            place = 0,
            name = "opaque-result",
            diagnose_discarded_result = true,
        },
        kvist.Ownership_IR_Shadow_Place{
            place = 1,
            name = "native-result",
            diagnose_discarded_result = true,
        },
    )
    shadow := kvist.Ownership_IR_Shadow_Proc{
        graph = graph,
        places = places,
    }
    cleanup := kvist.ownership_ir_analyze(graph)
    defer kvist.ownership_ir_analysis_delete(&cleanup)
    values := kvist.ownership_ir_analyze_value_liveness(graph)
    defer kvist.ownership_ir_analysis_delete(&values)
    plan := kvist.ownership_ir_build_cleanup_plan(shadow, cleanup)
    defer kvist.ownership_ir_cleanup_plan_delete(&plan)
    kvist.ownership_ir_append_value_diagnostics(shadow, values, &plan)

    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_need(cleanup.blocks[block].exit[0]),
        kvist.Ownership_IR_Cleanup_Need.None,
    )
    testing.expect_value(
        t,
        kvist.ownership_ir_cleanup_need(cleanup.blocks[block].exit[1]),
        kvist.Ownership_IR_Cleanup_Need.None,
    )
    testing.expect_value(t, len(plan.diagnostics), 1)
    if len(plan.diagnostics) == 1 {
        testing.expect_value(
            t,
            plan.diagnostics[0].kind,
            kvist.Ownership_IR_Diagnostic_Kind.Discarded_Result,
        )
        testing.expect_value(t, plan.diagnostics[0].subject, "opaque-result")
    }
}

@(test)
ownership_ir_shadow_lowers_real_resource_control_flow :: proc(t: ^testing.T) {
    source := `(package main)
(import os "core:os")

(defn read-wrapper [path: string] -> [data: []byte, err: os.Error]
  (os.read_entire_file path context.allocator))

(defn close-wrapper [file: ^os.File]
  (os.close file))

(defn direct-read [path: string] -> int
  (let [[data err] (os.read_entire_file path context.allocator)]
    (if (= err nil) (count data) 0)))

(defn simple-read [path: string] -> int
  (let [[data err] (os.read_entire_file path context.allocator)]
    (count data)))

(defn wrapped-read [path: string] -> int
  (let [[data err] (read-wrapper path)]
    (if (= err nil) (count data) 0)))

(defn direct-open [path: string] -> bool
  (let [[file err] (os.open path)]
    (= err nil)))

(defn transfer-read [path: string] -> []byte
  (let [[data err] (os.read_entire_file path context.allocator)]
    data))

(defn alias-transfer [path: string] -> []byte
  (let [[data err] (os.read_entire_file path context.allocator)
        alias data]
    alias))

(defn explicit-close [path: string] -> bool
  (let [[file err] (os.open path)]
    (os.close file)
    (= err nil)))

(defn deferred-read [path: string] -> int
  (let [[data err] (os.read_entire_file path context.allocator)]
    (defer (delete data))
    (if (= err nil) (count data) 0)))

(defn deferred-close [path: string] -> bool
  (let [[file err] (os.open path)]
    (defer (os.close file))
    (= err nil)))

(defn wrapped-close [path: string] -> bool
  (let [[file err] (os.open path)]
    (close-wrapper file)
    (= err nil)))

(defn errdeferred-read [path: string] -> [data: []byte, err: os.Error]
  (let [[data err] (read-wrapper path) :or-return :errdefer]
    (return data err)))

(defn split-return [left: string, right: string, choose-left?: bool] -> []byte
  (let [[left-data left-err] (os.read_entire_file left context.allocator)
        [right-data right-err] (os.read_entire_file right context.allocator)]
    (if choose-left? (return left-data))
    right-data))

(defn loop-cleanup [path: string, stop?: bool] -> int
  (while true
    (let [[data err] (os.read_entire_file path context.allocator)]
      (if stop? (break))
      (delete data)
      (continue)))
  0)

(defn fallthrough-cleanup [path: string, transfer?: bool] -> []byte
  (let [[data err] (os.read_entire_file path context.allocator)]
    (if transfer? (return data))
    (discard (count data)))
  nil)

(defn branch-delete [path: string, release?: bool] -> int
  (let [[data err] (os.read_entire_file path context.allocator)]
    (if release? (delete data) 0)
    1))`

    report, err, ok := kvist.ownership_ir_shadow_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(report)

    output, compile_err, compiled := kvist.compile_source(source)
    testing.expect_value(t, compiled, true)
    if !compiled {
        testing.expect_value(t, compile_err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(
        t,
        strings.contains(report, "direct_read\tdata\tengine=always\tlegacy=always\tmatch=true\tcleanup=delete"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "simple_read\tdata\tengine=always\tlegacy=always\tmatch=true\tcleanup=delete\tscheduled=0\ttransfers=0\texits=1\tplan-always=1\tplan-conditional=0\tplan-none=0\tplacement=scope-defer\tadoptable=true"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "direct_read\tdata\tengine=always\tlegacy=always\tmatch=true\tcleanup=delete\tscheduled=0\ttransfers=0\texits=2\tplan-always=2\tplan-conditional=0\tplan-none=0\tplacement=scope-defer\tadoptable=true"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "wrapped_read\tdata\tengine=always\tlegacy=always\tmatch=true\tcleanup=delete"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "direct_open\tfile\tengine=conditional\tlegacy=conditional\tmatch=true\tcleanup=os.close\tscheduled=0\ttransfers=0\texits=1\tplan-always=0\tplan-conditional=1\tplan-none=0\tplacement=scope-defer\tadoptable=true\tboundaries="),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "transfer_read\tdata\tengine=none\tlegacy=none\tmatch=true\tcleanup=delete"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "alias_transfer\tdata\tengine=none\tlegacy=none\tmatch=true\tcleanup=delete"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "explicit_close\tfile\tengine=none\tlegacy=none\tmatch=true\tcleanup=os.close"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "deferred_read\tdata\tengine=none\tlegacy=none\tmatch=true\tcleanup=delete\tscheduled=1\ttransfers=0"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "deferred_close\tfile\tengine=none\tlegacy=none\tmatch=true\tcleanup=os.close\tscheduled=1\ttransfers=0"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "wrapped_close\tfile\tengine=none\tlegacy=none\tmatch=true\tcleanup=os.close\tscheduled=0\ttransfers=1"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "errdeferred_read\tdata\tengine=none\tlegacy=none\tmatch=true\tcleanup=delete\tscheduled=1\ttransfers=0"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "split_return\tleft_data\tengine=conditional"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "split_return\tright_data\tengine=conditional"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "loop_cleanup\tdata\tengine=conditional"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "cleanup=delete\tscheduled=0\ttransfers=0\texits=2\tplan-always=1\tplan-conditional=0\tplan-none=1\tplacement=per-exit\tadoptable=true\tboundaries="),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "/break/always"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "/continue/none"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "fallthrough_cleanup\tdata\tengine=conditional\tlegacy=none\tmatch=false\tcleanup=delete\tscheduled=0\ttransfers=0\texits=2\tplan-always=1\tplan-conditional=0\tplan-none=1\tplacement=per-exit\tadoptable=true\tboundaries="),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "/fallthrough/always"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(report, "branch_delete\tdata\tengine=conditional\tlegacy=none\tmatch=false\tcleanup=delete"),
        true,
    )
}

@(test)
compiler_adopts_validated_ownership_plans :: proc(t: ^testing.T) {
    source := `(package main)
(import os "core:os")

(defn read-once [path: string] -> int
  (let [[data err] (os.read_entire_file path context.allocator)]
    (count data)))

(defn open-once [path: string] -> bool
  (let [[file err] (os.open path)]
    (= err nil)))

(defn branched-read [path: string] -> int
  (let [[data err] (os.read_entire_file path context.allocator)]
    (if (= err nil) (count data) 0)))

(defn branched-open [path: string] -> bool
  (let [[file err] (os.open path)]
    (if (= err nil) (!= file nil) false)))

(defn mixed-loop [path: string, stop?: bool] -> int
  (while true
    (let [[loop-data loop-err] (os.read_entire_file path context.allocator)]
      (if stop? (break))
      (delete loop-data)
      (continue)))
  0)

(defn mixed-continue [path: string, stop?: bool] -> int
  (while true
    (let [[continue-data continue-err] (os.read_entire_file path context.allocator)]
      (if stop?
        (do
          (delete continue-data)
          (break)))
      (continue)))
  0)

(defn nested-loop [left-path: string, right-path: string, stop?: bool] -> int
  (while true
    (let [[left-data left-err] (os.read_entire_file left-path context.allocator)
          [right-data right-err] (os.read_entire_file right-path context.allocator)]
      (if stop? (break))
      (delete right-data)
      (delete left-data)
      (continue)))
  0)

(defn return-choice [path: string, transfer?: bool] -> []byte
  (let [[return-data return-err] (os.read_entire_file path context.allocator)]
    (if transfer?
      (return return-data)
      (return nil))))

(defn return-pair [path: string, transfer?: bool] -> [data: []byte, ok: bool]
  (let [[pair-data pair-err] (os.read_entire_file path context.allocator)]
    (if transfer?
      (return pair-data true)
      (return nil false))))

(defn return-two [left-path: string, right-path: string, transfer?: bool] -> [left: []byte, right: []byte]
  (let [[return-left return-left-err] (os.read_entire_file left-path context.allocator)
        [return-right return-right-err] (os.read_entire_file right-path context.allocator)]
    (if transfer?
      (return return-left return-right)
      (return nil nil))))

(defn tail-choice [path: string, transfer?: bool] -> []byte
  (let [[tail-data tail-err] (os.read_entire_file path context.allocator)]
    (if transfer?
      tail-data
      nil)))

(defn empty-bytes [] -> []byte
  nil)

(defn tail-call-choice [path: string, transfer?: bool] -> []byte
  (let [[call-data call-err] (os.read_entire_file path context.allocator)]
    (if transfer?
      call-data
      (empty-bytes))))

(defn return-file-choice [path: string, transfer?: bool] -> ^os.File
  (let [[return-file return-file-err] (os.open path)]
    (if transfer?
      (return return-file)
      (return nil))))

(defn conditional-loop [path: string, stop?: bool] -> int
  (while true
    (let [[loop-file loop-file-err] (os.open path)]
      (if stop? (break))
      (if (= loop-file-err nil)
        (do
          (os.close loop-file)
          (continue))
        (continue))))
  0)

(defn conditional-loop-lifo [left-path: string, right-path: string, stop?: bool] -> int
  (while true
    (let [[loop-left loop-left-err] (os.open left-path)
          [loop-right loop-right-err] (os.open right-path)]
      (if stop? (break))
      (if (= loop-right-err nil)
        (do
          (os.close loop-right)
          (if (= loop-left-err nil)
            (do
              (os.close loop-left)
              (break))
            (break)))
        (if (= loop-left-err nil)
          (do
            (os.close loop-left)
            (break))
          (break)))))
  0)

(defn mixed-edge-kinds [path: string, transfer?: bool, stop?: bool] -> []byte
  (while true
    (let [[mixed-data mixed-err] (os.read_entire_file path context.allocator)]
      (if transfer? (return mixed-data))
      (if stop? (break))
      (delete mixed-data)
      (continue)))
  nil)

(defn fallthrough-edge [path: string, transfer?: bool] -> []byte
  (let [[fallthrough-data fallthrough-err] (os.read_entire_file path context.allocator)]
    (if transfer? (return fallthrough-data))
    (discard (count fallthrough-data)))
  nil)

(defn conditional-fallthrough-edge [path: string, transfer?: bool] -> ^os.File
  (let [[fallthrough-file fallthrough-file-err] (os.open path)]
    (if transfer? (return fallthrough-file))
    (discard fallthrough-file-err))
  nil)

(defn loop-fallthrough-edge [path: string, transfer?: bool] -> []byte
  (while true
    (let [[loop-fallthrough-data loop-fallthrough-err] (os.read_entire_file path context.allocator)]
      (if transfer? (return loop-fallthrough-data))
      (discard (count loop-fallthrough-data))))
  nil)

(defn merged-owner-state [path: string, transfer?: bool, release?: bool] -> []byte
  (let [[merged-data merged-err] (os.read_entire_file path context.allocator)]
    (if transfer? (return merged-data))
    (if release? (delete merged-data))
    (discard merged-err))
  nil)

(defn merged-custom-owner-state [path: string, transfer?: bool, release?: bool] -> ^os.File
  (let [[merged-file merged-file-err] (os.open path)]
    (if transfer? (return merged-file))
    (if release? (os.close merged-file))
    (discard merged-file-err))
  nil)

(defn consume-bytes [data: []byte]
  (delete data))

(defstruct Owned-Bytes [data: []byte])

(defn transferred-owner-state [path: string, return?: bool, consume?: bool] -> []byte
  (let [[transferred-data transferred-err] (os.read_entire_file path context.allocator)]
    (if return? (return transferred-data))
    (if consume? (consume-bytes transferred-data))
    (discard transferred-err))
  nil)

(defn stored-owner-state [path: string, return?: bool, store?: bool] -> []byte
  (defvar stored-slot: []byte nil)
  (let [[stored-data stored-err] (os.read_entire_file path context.allocator)]
    (if return? (return stored-data))
    (if store? (set! stored-slot stored-data))
    (discard stored-err))
  (delete stored-slot)
  nil)

(defn structured-owner-state [path: string, return?: bool, store?: bool] -> []byte
  (let [[structured-data structured-err] (os.read_entire_file path context.allocator)]
    (if return? (return structured-data))
    (if store?
      (Owned-Bytes :data structured-data)
      (discard 0))
    (discard structured-err))
  nil)

(defn discarded-empty-struct []
  (Owned-Bytes :data nil))

(defn bound-structured-owner [path: string] -> int
  (let [[bound-data bound-err] (os.read_entire_file path context.allocator)]
    (let [bound-box (Owned-Bytes :data bound-data)]
      (discard (count bound-box.data)))
    (discard bound-err))
  0)

(defn manually-cleaned-structured-owner [path: string] -> int
  (let [[manual-data manual-err] (os.read_entire_file path context.allocator)]
    (let [manual-box (Owned-Bytes :data manual-data)]
      (delete manual-box.data))
    (discard manual-err))
  0)

(defn conditionally-cleaned-structured-owner [path: string, release?: bool] -> int
  (let [[conditional-data conditional-err] (os.read_entire_file path context.allocator)]
    (let [conditional-box (Owned-Bytes :data conditional-data)]
      (if release? (delete conditional-box.data)))
    (discard conditional-err))
  0)

(defn shadowed-structured-owners [left-path: string, right-path: string] -> int
  (let [[outer-structured-data outer-structured-err] (os.read_entire_file left-path context.allocator)]
    (let [shadow-box (Owned-Bytes :data outer-structured-data)]
      (let [[inner-structured-data inner-structured-err] (os.read_entire_file right-path context.allocator)
            shadow-box (Owned-Bytes :data inner-structured-data)]
        (discard (count shadow-box.data))
        (discard inner-structured-err))
      (discard (count shadow-box.data)))
    (discard outer-structured-err))
  0)

(defn make-owned-bytes [path: string] -> Owned-Bytes
  (let [[factory-data factory-err] (os.read_entire_file path context.allocator)]
    (discard factory-err)
    (Owned-Bytes :data factory-data)))

(defn forward-owned-bytes [path: string] -> Owned-Bytes
  (make-owned-bytes path))

(defn use-returned-owner [path: string] -> int
  (let [returned-box (make-owned-bytes path)]
    (count returned-box.data)))

(defn use-forwarded-owner [path: string] -> int
  (let [forwarded-box (forward-owned-bytes path)]
    (count forwarded-box.data)))

(defn manually-clean-returned-owner [path: string] -> int
  (let [manual-returned-box (make-owned-bytes path)]
    (delete manual-returned-box.data)
    0))

(defn discard-returned-owner [path: string]
  (make-owned-bytes path))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, result.ownership_plan_adoptions, 34)
    testing.expect_value(t, strings.contains(result.output, "defer delete(data)"), true)
    testing.expect_value(t, strings.contains(result.output, "if err == nil"), true)
    testing.expect_value(t, strings.contains(result.output, "os.close(file)"), true)
    testing.expect_value(t, strings.count(result.output, "delete(loop_data)"), 2)
    first_loop_cleanup := strings.index(result.output, "delete(loop_data)")
    loop_break := strings.index(result.output, "break")
    second_loop_cleanup := -1
    if first_loop_cleanup >= 0 {
        after_first := first_loop_cleanup + len("delete(loop_data)")
        second_relative := strings.index(
            result.output[after_first:],
            "delete(loop_data)",
        )
        if second_relative >= 0 {
            second_loop_cleanup = after_first + second_relative
        }
    }
    testing.expect_value(
        t,
        first_loop_cleanup >= 0 &&
            first_loop_cleanup < loop_break &&
            loop_break < second_loop_cleanup,
        true,
    )
    testing.expect_value(
        t,
        strings.count(result.output, "delete(continue_data)"),
        2,
    )
    first_continue_cleanup := strings.index(
        result.output,
        "delete(continue_data)",
    )
    loop_continue := strings.last_index(result.output, "continue\n")
    second_continue_cleanup := -1
    if first_continue_cleanup >= 0 {
        after_first := first_continue_cleanup + len("delete(continue_data)")
        second_relative := strings.index(
            result.output[after_first:],
            "delete(continue_data)",
        )
        if second_relative >= 0 {
            second_continue_cleanup = after_first + second_relative
        }
    }
    testing.expect_value(
        t,
        first_continue_cleanup >= 0 &&
            first_continue_cleanup < second_continue_cleanup &&
            second_continue_cleanup < loop_continue,
        true,
    )
    nested_start := strings.index(result.output, "nested_loop :: proc")
    nested_ordered := false
    if nested_start >= 0 {
        nested_output := result.output[nested_start:]
        first_right := strings.index(nested_output, "delete(right_data)")
        first_left := strings.index(nested_output, "delete(left_data)")
        nested_break := strings.index(nested_output, "break")
        second_right := -1
        second_left := -1
        if first_right >= 0 {
            after_right := first_right + len("delete(right_data)")
            relative := strings.index(
                nested_output[after_right:],
                "delete(right_data)",
            )
            if relative >= 0 {
                second_right = after_right + relative
            }
        }
        if first_left >= 0 {
            after_left := first_left + len("delete(left_data)")
            relative := strings.index(
                nested_output[after_left:],
                "delete(left_data)",
            )
            if relative >= 0 {
                second_left = after_left + relative
            }
        }
        nested_ordered = first_right >= 0 &&
                         first_right < first_left &&
                         first_left < nested_break &&
                         nested_break < second_right &&
                         second_right < second_left
    }
    testing.expect_value(t, nested_ordered, true)
    return_start := strings.index(result.output, "return_choice :: proc")
    return_ordered := false
    if return_start >= 0 {
        return_output := result.output[return_start:]
        transferred := strings.index(return_output, "return return_data")
        temp_assignment := strings.index(return_output, "kvist_thread_")
        cleanup := strings.index(return_output, "delete(return_data)")
        temp_return := strings.last_index(return_output, "return kvist_thread_")
        return_ordered = transferred >= 0 &&
                         transferred < temp_assignment &&
                         temp_assignment < cleanup &&
                         cleanup < temp_return
    }
    testing.expect_value(t, return_ordered, true)
    testing.expect_value(t, strings.count(result.output, "delete(return_data)"), 1)
    pair_start := strings.index(result.output, "return_pair :: proc")
    pair_ordered := false
    if pair_start >= 0 {
        pair_output := result.output[pair_start:]
        transferred := strings.index(pair_output, "return pair_data, true")
        first_temp := strings.index(pair_output, "kvist_thread_")
        cleanup := strings.index(pair_output, "delete(pair_data)")
        temp_return := strings.last_index(pair_output, "return kvist_thread_")
        pair_ordered = transferred >= 0 &&
                       transferred < first_temp &&
                       first_temp < cleanup &&
                       cleanup < temp_return
    }
    testing.expect_value(t, pair_ordered, true)
    testing.expect_value(t, strings.count(result.output, "delete(pair_data)"), 1)
    two_start := strings.index(result.output, "return_two :: proc")
    two_ordered := false
    if two_start >= 0 {
        two_output := result.output[two_start:]
        transferred := strings.index(
            two_output,
            "return return_left, return_right",
        )
        first_temp := strings.index(two_output, "kvist_thread_")
        right_cleanup := strings.index(two_output, "delete(return_right)")
        left_cleanup := strings.index(two_output, "delete(return_left)")
        temp_return := strings.last_index(two_output, "return kvist_thread_")
        two_ordered = transferred >= 0 &&
                      transferred < first_temp &&
                      first_temp < right_cleanup &&
                      right_cleanup < left_cleanup &&
                      left_cleanup < temp_return
    }
    testing.expect_value(t, two_ordered, true)
    testing.expect_value(t, strings.count(result.output, "delete(return_left)"), 1)
    testing.expect_value(t, strings.count(result.output, "delete(return_right)"), 1)
    tail_start := strings.index(result.output, "tail_choice :: proc")
    tail_ordered := false
    if tail_start >= 0 {
        tail_output := result.output[tail_start:]
        transferred := strings.index(tail_output, "return tail_data")
        temp_assignment := strings.index(tail_output, "kvist_thread_")
        cleanup := strings.index(tail_output, "delete(tail_data)")
        temp_return := strings.last_index(tail_output, "return kvist_thread_")
        tail_ordered = transferred >= 0 &&
                       transferred < temp_assignment &&
                       temp_assignment < cleanup &&
                       cleanup < temp_return
    }
    testing.expect_value(t, tail_ordered, true)
    testing.expect_value(t, strings.count(result.output, "delete(tail_data)"), 1)
    call_start := strings.index(result.output, "tail_call_choice :: proc")
    call_ordered := false
    if call_start >= 0 {
        call_output := result.output[call_start:]
        transferred := strings.index(call_output, "return call_data")
        evaluated := strings.index(call_output, "empty_bytes()")
        cleanup := strings.index(call_output, "delete(call_data)")
        temp_return := strings.last_index(call_output, "return kvist_thread_")
        call_ordered = transferred >= 0 &&
                       transferred < evaluated &&
                       evaluated < cleanup &&
                       cleanup < temp_return
    }
    testing.expect_value(t, call_ordered, true)
    testing.expect_value(t, strings.count(result.output, "delete(call_data)"), 1)
    file_start := strings.index(result.output, "return_file_choice :: proc")
    file_ordered := false
    if file_start >= 0 {
        file_output := result.output[file_start:]
        owner_snapshot := strings.index(
            file_output,
            ":= return_file_err == nil",
        )
        transferred := strings.index(file_output, "return return_file")
        temp_assignment := strings.index(file_output, "kvist_thread_")
        guarded_cleanup := strings.index(file_output, "if kvist_owner_")
        cleanup := strings.index(file_output, "os.close(return_file)")
        temp_return := strings.last_index(file_output, "return kvist_thread_")
        file_ordered = owner_snapshot >= 0 &&
                       owner_snapshot < transferred &&
                       transferred < temp_assignment &&
                       temp_assignment < guarded_cleanup &&
                       guarded_cleanup < cleanup &&
                       cleanup < temp_return
    }
    testing.expect_value(t, file_ordered, true)
    testing.expect_value(t, strings.count(result.output, "os.close(return_file)"), 1)
    conditional_lifo_start := strings.index(
        result.output,
        "conditional_loop_lifo :: proc",
    )
    conditional_loop_start := strings.index(
        result.output,
        "conditional_loop :: proc",
    )
    conditional_loop_ordered := false
    if conditional_loop_start >= 0 &&
       conditional_lifo_start > conditional_loop_start {
        loop_output := result.output[
            conditional_loop_start:conditional_lifo_start
        ]
        owner_snapshot := strings.index(
            loop_output,
            ":= loop_file_err == nil",
        )
        first_guard := strings.index(loop_output, "if kvist_owner_")
        first_cleanup := strings.index(loop_output, "os.close(loop_file)")
        first_break := strings.index(loop_output, "break")
        last_guard := strings.last_index(loop_output, "if kvist_owner_")
        last_cleanup := strings.last_index(loop_output, "os.close(loop_file)")
        last_continue := strings.last_index(loop_output, "continue")
        conditional_loop_ordered = owner_snapshot >= 0 &&
                                   owner_snapshot < first_guard &&
                                   first_guard < first_cleanup &&
                                   first_cleanup < first_break &&
                                   first_break < last_guard &&
                                   last_guard < last_cleanup &&
                                   last_cleanup < last_continue
    }
    testing.expect_value(t, conditional_loop_ordered, true)
    testing.expect_value(
        t,
        strings.count(result.output, "os.close(loop_file)"),
        3,
    )
    conditional_lifo_ordered := false
    if conditional_lifo_start >= 0 {
        lifo_output := result.output[conditional_lifo_start:]
        left_snapshot := strings.index(
            lifo_output,
            ":= loop_left_err == nil",
        )
        right_snapshot := strings.index(
            lifo_output,
            ":= loop_right_err == nil",
        )
        first_right_cleanup := strings.index(
            lifo_output,
            "os.close(loop_right)",
        )
        first_left_cleanup := strings.index(
            lifo_output,
            "os.close(loop_left)",
        )
        first_break := strings.index(lifo_output, "break")
        conditional_lifo_ordered = left_snapshot >= 0 &&
                                   left_snapshot < right_snapshot &&
                                   right_snapshot < first_right_cleanup &&
                                   first_right_cleanup < first_left_cleanup &&
                                   first_left_cleanup < first_break
    }
    testing.expect_value(t, conditional_lifo_ordered, true)
    mixed_start := strings.index(result.output, "mixed_edge_kinds :: proc")
    mixed_ordered := false
    if mixed_start >= 0 {
        mixed_output := result.output[mixed_start:]
        transferred := strings.index(mixed_output, "return mixed_data")
        first_cleanup := strings.index(mixed_output, "delete(mixed_data)")
        loop_break := strings.index(mixed_output, "break")
        second_cleanup := strings.last_index(mixed_output, "delete(mixed_data)")
        loop_continue := strings.last_index(mixed_output, "continue")
        mixed_ordered = transferred >= 0 &&
                        transferred < first_cleanup &&
                        first_cleanup < loop_break &&
                        loop_break < second_cleanup &&
                        second_cleanup < loop_continue
    }
    testing.expect_value(t, mixed_ordered, true)
    testing.expect_value(t, strings.count(result.output, "delete(mixed_data)"), 2)
    fallthrough_start := strings.index(
        result.output,
        "fallthrough_edge :: proc",
    )
    conditional_fallthrough_start := strings.index(
        result.output,
        "conditional_fallthrough_edge :: proc",
    )
    fallthrough_ordered := false
    if fallthrough_start >= 0 &&
       conditional_fallthrough_start > fallthrough_start {
        fallthrough_output := result.output[
            fallthrough_start:conditional_fallthrough_start
        ]
        transferred := strings.index(
            fallthrough_output,
            "return fallthrough_data",
        )
        borrowed := strings.index(fallthrough_output, "len(fallthrough_data)")
        cleanup := strings.index(
            fallthrough_output,
            "delete(fallthrough_data)",
        )
        final_return := strings.last_index(fallthrough_output, "return nil")
        fallthrough_ordered = transferred >= 0 &&
                              transferred < borrowed &&
                              borrowed < cleanup &&
                              cleanup < final_return
    }
    testing.expect_value(t, fallthrough_ordered, true)
    testing.expect_value(
        t,
        strings.count(result.output, "delete(fallthrough_data)"),
        1,
    )
    conditional_fallthrough_ordered := false
    if conditional_fallthrough_start >= 0 {
        fallthrough_output := result.output[conditional_fallthrough_start:]
        owner_snapshot := strings.index(
            fallthrough_output,
            ":= fallthrough_file_err == nil",
        )
        transferred := strings.index(
            fallthrough_output,
            "return fallthrough_file",
        )
        guarded_cleanup := strings.index(fallthrough_output, "if kvist_owner_")
        cleanup := strings.index(
            fallthrough_output,
            "os.close(fallthrough_file)",
        )
        final_return := strings.last_index(fallthrough_output, "return nil")
        conditional_fallthrough_ordered = owner_snapshot >= 0 &&
                                          owner_snapshot < transferred &&
                                          transferred < guarded_cleanup &&
                                          guarded_cleanup < cleanup &&
                                          cleanup < final_return
    }
    testing.expect_value(t, conditional_fallthrough_ordered, true)
    testing.expect_value(
        t,
        strings.count(result.output, "os.close(fallthrough_file)"),
        1,
    )
    loop_fallthrough_start := strings.index(
        result.output,
        "loop_fallthrough_edge :: proc",
    )
    loop_fallthrough_ordered := false
    if loop_fallthrough_start >= 0 {
        loop_output := result.output[loop_fallthrough_start:]
        transferred := strings.index(
            loop_output,
            "return loop_fallthrough_data",
        )
        borrowed := strings.index(
            loop_output,
            "len(loop_fallthrough_data)",
        )
        cleanup := strings.index(
            loop_output,
            "delete(loop_fallthrough_data)",
        )
        loop_fallthrough_ordered = transferred >= 0 &&
                                   transferred < borrowed &&
                                   borrowed < cleanup
    }
    testing.expect_value(t, loop_fallthrough_ordered, true)
    testing.expect_value(
        t,
        strings.count(result.output, "delete(loop_fallthrough_data)"),
        1,
    )
    merged_start := strings.index(
        result.output,
        "merged_owner_state :: proc",
    )
    merged_custom_start := strings.index(
        result.output,
        "merged_custom_owner_state :: proc",
    )
    transferred_start := strings.index(
        result.output,
        "transferred_owner_state :: proc",
    )
    stored_start := strings.index(
        result.output,
        "stored_owner_state :: proc",
    )
    structured_start := strings.index(
        result.output,
        "structured_owner_state :: proc",
    )
    merged_ordered := false
    if merged_start >= 0 && merged_custom_start > merged_start {
        merged_output := result.output[merged_start:merged_custom_start]
        owner_initialization := strings.index(merged_output, ":= true")
        first_cleanup := strings.index(merged_output, "delete(merged_data)")
        owner_clear := strings.index(merged_output, "= false")
        cleanup_guard := strings.last_index(merged_output, "if kvist_owner_")
        second_cleanup := strings.last_index(
            merged_output,
            "delete(merged_data)",
        )
        merged_ordered = owner_initialization >= 0 &&
                         owner_initialization < first_cleanup &&
                         first_cleanup < owner_clear &&
                         owner_clear < cleanup_guard &&
                         cleanup_guard < second_cleanup
    }
    testing.expect_value(t, merged_ordered, true)
    testing.expect_value(
        t,
        strings.count(result.output, "delete(merged_data)"),
        2,
    )
    merged_custom_ordered := false
    if merged_custom_start >= 0 && transferred_start > merged_custom_start {
        merged_output := result.output[merged_custom_start:transferred_start]
        owner_initialization := strings.index(
            merged_output,
            ":= merged_file_err == nil",
        )
        first_cleanup := strings.index(
            merged_output,
            "os.close(merged_file)",
        )
        owner_clear := strings.index(merged_output, "= false")
        cleanup_guard := strings.last_index(merged_output, "if kvist_owner_")
        second_cleanup := strings.last_index(
            merged_output,
            "os.close(merged_file)",
        )
        merged_custom_ordered = owner_initialization >= 0 &&
                                owner_initialization < first_cleanup &&
                                first_cleanup < owner_clear &&
                                owner_clear < cleanup_guard &&
                                cleanup_guard < second_cleanup
    }
    testing.expect_value(t, merged_custom_ordered, true)
    testing.expect_value(
        t,
        strings.count(result.output, "os.close(merged_file)"),
        2,
    )
    transferred_ordered := false
    if transferred_start >= 0 && stored_start > transferred_start {
        transferred_output := result.output[transferred_start:stored_start]
        owner_initialization := strings.index(transferred_output, ":= true")
        transferred_return := strings.index(
            transferred_output,
            "return transferred_data",
        )
        consuming_call := strings.index(
            transferred_output,
            "consume_bytes(",
        )
        owner_clear := strings.index(transferred_output, "= false")
        cleanup_guard := strings.last_index(
            transferred_output,
            "if kvist_owner_",
        )
        cleanup := strings.index(
            transferred_output,
            "delete(transferred_data)",
        )
        transferred_ordered = owner_initialization >= 0 &&
                              owner_initialization < transferred_return &&
                              transferred_return < consuming_call &&
                              consuming_call < owner_clear &&
                              owner_clear < cleanup_guard &&
                              cleanup_guard < cleanup
    }
    testing.expect_value(t, transferred_ordered, true)
    testing.expect_value(
        t,
        strings.count(result.output, "delete(transferred_data)"),
        1,
    )
    stored_ordered := false
    if stored_start >= 0 && structured_start > stored_start {
        stored_output := result.output[stored_start:structured_start]
        owner_initialization := strings.index(stored_output, ":= true")
        stored_return := strings.index(stored_output, "return stored_data")
        managed_assignment := strings.index(stored_output, "stored_slot = ")
        owner_clear := strings.index(stored_output, "= false")
        cleanup_guard := strings.last_index(stored_output, "if kvist_owner_")
        local_cleanup := strings.index(stored_output, "delete(stored_data)")
        stored_cleanup := strings.index(stored_output, "delete(stored_slot)")
        stored_ordered = owner_initialization >= 0 &&
                         owner_initialization < stored_return &&
                         stored_return < managed_assignment &&
                         managed_assignment < owner_clear &&
                         owner_clear < cleanup_guard &&
                         cleanup_guard < local_cleanup &&
                         local_cleanup < stored_cleanup
    }
    testing.expect_value(t, stored_ordered, true)
    testing.expect_value(
        t,
        strings.count(result.output, "delete(stored_data)"),
        1,
    )
    structured_ordered := false
    if structured_start >= 0 {
        structured_output := result.output[structured_start:]
        owner_initialization := strings.index(structured_output, ":= true")
        structured_return := strings.index(
            structured_output,
            "return structured_data",
        )
        construction := strings.index(
            structured_output,
            ":= Owned_Bytes{data = ",
        )
        owner_clear := strings.index(structured_output, "= false")
        aggregate_cleanup := strings.index(
            structured_output,
            "delete(kvist_thread_",
        )
        cleanup_guard := strings.last_index(
            structured_output,
            "if kvist_owner_",
        )
        cleanup := strings.index(
            structured_output,
            "delete(structured_data)",
        )
        structured_ordered = owner_initialization >= 0 &&
                             owner_initialization < structured_return &&
                             structured_return < construction &&
                             construction < owner_clear &&
                             owner_clear < aggregate_cleanup &&
                             aggregate_cleanup < cleanup_guard &&
                             cleanup_guard < cleanup
    }
    testing.expect_value(t, structured_ordered, true)
    testing.expect_value(
        t,
        strings.count(result.output, "delete(structured_data)"),
        1,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "_ = Owned_Bytes{data = nil}"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(bound_box.data)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(manual_box.data)"),
        false,
    )
    testing.expect_value(
        t,
        strings.count(result.output, "delete(manual_box.data)"),
        1,
    )
    conditional_start := strings.index(
        result.output,
        "conditionally_cleaned_structured_owner :: proc",
    )
    conditional_cleanup_ordered := false
    if conditional_start >= 0 {
        conditional_output := result.output[conditional_start:]
        field_binding := strings.index(
            conditional_output,
            "conditional_box := Owned_Bytes{data = ",
        )
        field_owner := strings.index(conditional_output, ":= true")
        deferred_cleanup := strings.index(
            conditional_output,
            "&(conditional_box.data)",
        )
        explicit_cleanup := strings.index(
            conditional_output,
            "delete(conditional_box.data)",
        )
        owner_clear := strings.last_index(conditional_output, "= false")
        conditional_cleanup_ordered = field_binding >= 0 &&
                                      field_binding < field_owner &&
                                      field_owner < deferred_cleanup &&
                                      deferred_cleanup < explicit_cleanup &&
                                      explicit_cleanup < owner_clear
    }
    testing.expect_value(t, conditional_cleanup_ordered, true)
    shadowed_start := strings.index(
        result.output,
        "shadowed_structured_owners :: proc",
    )
    shadowed_cleanup_count := 0
    if shadowed_start >= 0 {
        shadowed_cleanup_count = strings.count(
            result.output[shadowed_start:],
            "defer delete(shadow_box.data)",
        )
    }
    testing.expect_value(t, shadowed_cleanup_count, 2)
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(returned_box.data)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(forwarded_box.data)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(
            result.output,
            "defer delete(manual_returned_box.data)",
        ),
        false,
    )
    testing.expect_value(
        t,
        strings.count(result.output, "delete(manual_returned_box.data)"),
        1,
    )
    discard_returned_start := strings.index(
        result.output,
        "discard_returned_owner :: proc",
    )
    discard_returned_cleanup := false
    if discard_returned_start >= 0 {
        discard_output := result.output[discard_returned_start:]
        materialized := strings.index(
            discard_output,
            ":= make_owned_bytes(path)",
        )
        cleanup := strings.index(discard_output, "delete(kvist_thread_")
        discard_returned_cleanup = materialized >= 0 &&
                                     materialized < cleanup &&
                                     strings.contains(
                                         discard_output,
                                         ".data)",
                                     )
    }
    testing.expect_value(t, discard_returned_cleanup, true)
}

@(test)
warn_when_native_aggregate_field_cleanup_is_unsafe :: proc(t: ^testing.T) {
    source := `(package main)
(import os "core:os")

(defstruct Owned-Bytes [data: []byte])

(defn replace-field [path: string, replacement: []byte] -> int
  (let [[data err] (os.read_entire_file path context.allocator)]
    (let [box (Owned-Bytes :data data)]
      (set! box.data replacement)
      (discard (count box.data)))
    (discard err))
  0)`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(box.data)"),
        false,
    )
    testing.expect_value(t, len(result.warnings), 2)
    cleanup_skipped := false
    overwrite_diagnosed := false
    for warning in result.warnings {
        if warning.code == .Ownership_Automatic_Cleanup_Skipped {
            cleanup_skipped = true
            testing.expect_value(
                t,
                warning.message,
                "automatic cleanup for owned result `data` was skipped because it is stored in an aggregate or mutable place; clean it up explicitly after its last use or transfer ownership",
            )
        }
        if warning.code == .Ownership_Overwrite {
            overwrite_diagnosed = true
            testing.expect_value(
                t,
                warning.message,
                "owned local box.data is overwritten before cleanup; delete it or return it before set!",
            )
            testing.expect_value(
                t,
                warning.confidence,
                kvist.Compile_Warning_Confidence.Definite,
            )
        }
    }
    testing.expect_value(t, cleanup_skipped, true)
    testing.expect_value(t, overwrite_diagnosed, true)
}

@(test)
warn_when_aggregate_result_field_ownership_differs_by_branch :: proc(
    t: ^testing.T,
) {
    source := `(package main)
(import os "core:os")

(defstruct Owned-Bytes [data: []byte])

(defn maybe-owned-bytes [path: string, borrowed: []byte, own?: bool] -> Owned-Bytes
  (let [[data err] (os.read_entire_file path context.allocator)]
    (discard err)
    (if own?
      (Owned-Bytes :data data)
      (Owned-Bytes :data borrowed))))

(defn use [path: string, borrowed: []byte, own?: bool] -> int
  (let [box (maybe-owned-bytes path borrowed own?)]
    (count box.data)))

(defn early-maybe-owned-bytes [path: string, borrowed: []byte, own?: bool] -> Owned-Bytes
  (let [[data err] (os.read_entire_file path context.allocator)]
    (discard err)
    (if own?
      (return (Owned-Bytes :data data)))
    (Owned-Bytes :data borrowed)))

(defn use-early [path: string, borrowed: []byte, own?: bool] -> int
  (let [early-box (early-maybe-owned-bytes path borrowed own?)]
    (count early-box.data)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(box.data)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(early_box.data)"),
        false,
    )
    testing.expect_value(t, len(result.warnings), 2)
    testing.expect_value(
        t,
        strings.count(result.output, "delete(data)"),
        2,
    )
    aggregate_contract_warning_count := 0
    for warning in result.warnings {
        testing.expect_value(
            t,
            warning.code,
            kvist.Compile_Warning_Code.Ownership_Automatic_Cleanup_Skipped,
        )
        if strings.contains(
            warning.message,
            "ownership of fields in result",
        ) {
            aggregate_contract_warning_count += 1
        }
    }
    testing.expect_value(t, aggregate_contract_warning_count, 2)
}

@(test)
infer_aggregate_result_ownership_through_local_bindings :: proc(
    t: ^testing.T,
) {
    source := `(package main)
(import os "core:os")

(defstruct Owned-Bytes [data: []byte])

(defn make-local-owned-bytes [path: string] -> Owned-Bytes
  (let [[data err] (os.read_entire_file path context.allocator)
        boxed (Owned-Bytes :data data)]
    (discard err)
    (discard (count boxed.data))
    (return boxed)))

(defn make-aliased-owned-bytes [path: string] -> Owned-Bytes
  (let [[data err] (os.read_entire_file path context.allocator)
        boxed (Owned-Bytes :data data)
        forwarded boxed]
    (discard err)
    forwarded))

(defn use-local-owner [path: string] -> int
  (let [local-result (make-local-owned-bytes path)]
    (count local-result.data)))

(defn use-aliased-owner [path: string] -> int
  (let [alias-result (make-aliased-owned-bytes path)]
    (count alias-result.data)))

(defn manually-clean-local-owner [path: string] -> int
  (let [manual-result (make-local-owned-bytes path)]
    (delete manual-result.data)
    0))

(defn discard-local-owner [path: string]
  (make-local-owned-bytes path))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(local_result.data)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(alias_result.data)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(manual_result.data)"),
        false,
    )
    testing.expect_value(
        t,
        strings.count(result.output, "delete(manual_result.data)"),
        1,
    )
    make_start := strings.index(
        result.output,
        "make_local_owned_bytes :: proc",
    )
    use_start := strings.index(result.output, "use_local_owner :: proc")
    testing.expect(t, make_start >= 0 && use_start > make_start)
    if make_start >= 0 && use_start > make_start {
        maker_output := result.output[make_start:use_start]
        testing.expect_value(
            t,
            strings.contains(maker_output, "defer delete(boxed.data)"),
            false,
        )
    }
    discard_start := strings.index(
        result.output,
        "discard_local_owner :: proc",
    )
    discard_cleanup := false
    if discard_start >= 0 {
        discard_output := result.output[discard_start:]
        materialized := strings.index(
            discard_output,
            ":= make_local_owned_bytes(path)",
        )
        cleanup := strings.index(discard_output, "delete(kvist_thread_")
        discard_cleanup = materialized >= 0 &&
                          materialized < cleanup &&
                          strings.contains(discard_output, ".data)")
    }
    testing.expect_value(t, discard_cleanup, true)
}

@(test)
warn_when_returned_aggregate_owned_field_is_replaced :: proc(t: ^testing.T) {
    source := `(package main)
(import os "core:os")

(defstruct Owned-Bytes [data: []byte])

(defn replace-owned-field [path: string, borrowed: []byte] -> Owned-Bytes
  (let [[data err] (os.read_entire_file path context.allocator)
        boxed (Owned-Bytes :data data)]
    (discard err)
    (set! boxed.data borrowed)
    boxed))

(defn use [path: string, borrowed: []byte] -> int
  (let [box (replace-owned-field path borrowed)]
    (count box.data)))

(defn consume-bytes [value: []byte] -> int
  (delete value)
  0)

(defn transfer-owned-field [path: string] -> Owned-Bytes
  (let [[data err] (os.read_entire_file path context.allocator)
        boxed (Owned-Bytes :data data)
        consumed (consume-bytes boxed.data)]
    (discard err)
    (discard consumed)
    boxed))

(defn use-transferred [path: string] -> int
  (let [transferred-box (transfer-owned-field path)]
    (count transferred-box.data)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(box.data)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(
            result.output,
            "defer delete(transferred_box.data)",
        ),
        false,
    )
    aggregate_contract_warning_count := 0
    for warning in result.warnings {
        if warning.code ==
           kvist.Compile_Warning_Code.Ownership_Automatic_Cleanup_Skipped &&
           strings.contains(
               warning.message,
               "cannot be proven consistent across returns and mutations",
           ) {
            aggregate_contract_warning_count += 1
        }
    }
    testing.expect_value(t, aggregate_contract_warning_count, 2)
}

@(test)
reject_deferred_string_passed_to_consuming_proc :: proc(t: ^testing.T) {
    source := `(package main)
(import fmt "core:fmt")

(defn consume [value: string]
  (delete value))

(defn broken []
  (let [value (fmt.aprintf "sid=%s" "abc") :defer]
    (consume value)))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, false)
    delete(output)
    defer delete(err.message)
    testing.expect_value(
        t,
        err.message,
        "`value` has `:defer` cleanup, but ownership is transferred before scope exit; remove `:defer` to transfer ownership, or pass an owned copy",
    )
}

@(test)
reject_deferred_string_nested_in_consumed_struct :: proc(t: ^testing.T) {
    source := `(package main)
(import fmt "core:fmt")

(defstruct Cookie [value: string])
(defstruct Response [cookies: [dynamic]Cookie])

(defn new-cookie [value: string] -> Cookie
  (Cookie :value value))

(defn store-cookie! [response: ^Response, cookie: Cookie]
  (append (addr response.cookies) cookie))

(defn broken [response: ^Response]
  (let [value (fmt.aprintf "sid=%s" "abc") :defer]
    (store-cookie! response (new-cookie value))))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, false)
    delete(output)
    defer delete(err.message)
    testing.expect_value(
        t,
        err.message,
        "`value` has `:defer` cleanup, but ownership is transferred before scope exit; remove `:defer` to transfer ownership, or pass an owned copy",
    )
}

@(test)
reject_deferred_cleanup_after_conditional_transfer :: proc(t: ^testing.T) {
    source := `(package main)
(import fmt "core:fmt")

(defn consume [value: string]
  (delete value))

(defn broken [flag: bool]
  (let [value (fmt.aprintf "sid=%s" "abc") :defer]
    (if flag
      (consume value)
      (println "kept"))))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, false)
    delete(output)
    defer delete(err.message)
    testing.expect_value(
        t,
        err.message,
        "`value` has `:defer` cleanup, but ownership is transferred before scope exit; remove `:defer` to transfer ownership, or pass an owned copy",
    )
}

@(test)
compile_deferred_string_passed_to_borrowing_proc :: proc(t: ^testing.T) {
    source := `(package main)
(import fmt "core:fmt")

(defn inspect [value: string] -> int
  (count value))

(defn ok [] -> int
  (let [value (fmt.aprintf "sid=%s" "abc") :defer]
    (inspect value)))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        defer delete(err.message)
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)
    testing.expect_value(t, strings.contains(output, "defer delete(value)"), true)
    testing.expect_value(t, strings.contains(output, "return inspect(value)"), true)
}

@(test)
reject_shadowed_cleanup_for_outer_owned_let_binding :: proc(t: ^testing.T) {
    source := `(package main)
(import fmt "core:fmt")

(defn broken [] -> int
  (+ 1
     (let [label (fmt.aprintf "outer")]
       (let [label (fmt.aprintf "inner")]
         (delete label))
       2)))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, false)
    delete(output)
    defer delete(err.message)
    testing.expect_value(
        t,
        err.message,
        "fmt.aprintf returns an owned result; bind it so it can be cleaned up, or return it to transfer ownership",
    )
}

@(test)
compile_outer_owned_let_cleanup_after_shadowed_scope :: proc(t: ^testing.T) {
    source := `(package main)
(import fmt "core:fmt")

(defn valid [] -> int
  (+ 1
     (let [label (fmt.aprintf "outer")]
       (discard
         (let [label (fmt.aprintf "inner") :defer]
           (count label)))
       (delete label)
       2)))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.count(output, "delete(label)") >= 2, true)
}

@(test)
compile_owned_let_branch_case_in_return_position :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defenum Step-Kind [One Two])

(defstruct Step [
  kind: Step-Kind
])

(defn owned-from-case [step: Step] -> [dynamic]int
  (case step.kind
    .One
      (let [out (make [dynamic]int)]
        (arr.push! out 1)
        out)
    (let [out (make [dynamic]int)]
      (arr.push! out 2)
      out)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "kvist_owner^ = false; return kvist_value"), false)
}

@(test)
compile_owned_let_branch_mixed_with_owned_call_case :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defenum Step-Kind [One Two])

(defstruct Step [
  kind: Step-Kind
])

(defn make-one [] -> [dynamic]int
  (let [out (make [dynamic]int)]
    (arr.push! out 1)
    out))

(defn owned-from-mixed-case [step: Step] -> [dynamic]int
  (case step.kind
    .One
      (let [out (make [dynamic]int)]
        (arr.push! out 10)
        out)
    (make-one)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "kvist_owner^ = false; return kvist_value"), false)
    testing.expect_value(t, strings.contains(result.output, "return make_one()"), true)
}

@(test)
compile_rejects_removed_owned_struct_field_syntax :: proc(t: ^testing.T) {
    source := `(package main)

(defstruct Values [
  items: (owned []int)
])`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, false)
    delete(output)
    defer delete(err.message)
    testing.expect_value(
        t,
        err.message,
        "owned struct field types have been removed; field lifetimes are inferred from construction and decoding",
    )
}

@(test)
compile_local_declarations_do_not_escape_block_scope :: proc(t: ^testing.T) {
    source := `(package main)

(defstruct Local [name: string])

(defn broken [] -> int
  (do
    (defstruct Local [x: int]))
  (let [value (Local :x 1)]
    0))`

    _, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, false)
    if ok {
        return
    }
    defer delete(err.message)
    testing.expect_value(t, strings.contains(err.message, "unknown struct constructor field :x"), true)
}

@(test)
compile_core_str_constructs_one_owned_formatted_string :: proc(t: ^testing.T) {
    source := `(package main)

(defstruct Point [x: int y: int])

(defn render [path: string, point: Point] -> string
  (str "@get('" path "', {open: 100%}) " true " " 42 " " :ready " " point))

(defn empty [] -> string
  (str))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, `fmt.aprintf("%v%v%v%v%v%v%v%v%v%v"`), true)
    testing.expect_value(t, strings.contains(result.output, `"@get('"`), true)
    testing.expect_value(t, strings.contains(result.output, `"', {open: 100%}) "`), true)
    testing.expect_value(t, strings.contains(result.output, `fmt.aprintf("")`), true)
    testing.expect_value(t, len(result.warnings), 0)
}

@(test)
compile_with_allocator_scope :: proc(t: ^testing.T) {
    source := `(package main)

(defn main []
  (with-allocator [allocator context.temp_allocator]
    (let [buffer (make [dynamic]int)]
      (defer (delete buffer))
      (odin "append(&(buffer), ..[]int{1, 2})")
      (return))))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    expected := `package main

main :: proc() {
    {
        allocator := context.temp_allocator
        kvist_old_allocator_1 := context.allocator
        context.allocator = allocator
        defer context.allocator = kvist_old_allocator_1
        buffer := make([dynamic]int)
        defer delete(buffer)
        append(&(buffer), ..[]int{1, 2})
        return
    }
}
`
    testing.expect_value(t, output, expected)
}

@(test)
compile_with_temp_allocator_scope :: proc(t: ^testing.T) {
    source := `(package main)
(import runtime "base:runtime")

(defn main []
  (with-temp-allocator [allocator]
    (let [buffer (make [dynamic]int)]
      (defer (delete buffer))
      (odin "append(&(buffer), ..[]int{1, 2})")
      (return))))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    expected := `package main

import runtime "base:runtime"

main :: proc() {
    {
        kvist_temp_scope_1 := runtime.default_temp_allocator_temp_begin()
        defer runtime.default_temp_allocator_temp_end(kvist_temp_scope_1)
        allocator := context.temp_allocator
        kvist_old_allocator_2 := context.allocator
        context.allocator = allocator
        defer context.allocator = kvist_old_allocator_2
        buffer := make([dynamic]int)
        defer delete(buffer)
        append(&(buffer), ..[]int{1, 2})
        return
    }
}
`
    testing.expect_value(t, output, expected)
}

@(test)
compile_with_allocator_expression_with_expected_type :: proc(t: ^testing.T) {
    source := `(package main)

(defn id [x: int] -> int
  x)

(defn demo [] -> int
  (let [value: int (with-allocator [allocator context.temp_allocator]
                     (id 42))]
    value))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "value: int = (proc() -> int {"), true)
    testing.expect_value(t, strings.contains(output, "context.allocator = allocator"), true)
    testing.expect_value(t, strings.contains(output, "return id(42)"), true)
}

@(test)
compile_with_temp_allocator_expression_with_expected_type :: proc(t: ^testing.T) {
    source := `(package main)
(import runtime "base:runtime")

(defn id [x: int] -> int
  x)

(defn demo [] -> int
  (let [value: int (with-temp-allocator [allocator]
                     (id 42))]
    value))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "value: int = (proc() -> int {"), true)
    testing.expect_value(t, strings.contains(output, "runtime.default_temp_allocator_temp_begin()"), true)
    testing.expect_value(t, strings.contains(output, "return id(42)"), true)
}

@(test)
reject_untyped_with_allocator_expression :: proc(t: ^testing.T) {
    source := `(package main)

(defn demo []
  (let [value (with-allocator [allocator context.temp_allocator]
                42)]
    value))`

    _, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, false)
    defer delete(err.message)
    testing.expect_value(t, err.message, "with-allocator expression needs an expected type; add a let binding type or use it where the type is known")
}

@(test)
compile_final_with_allocator_uses_proc_return_type :: proc(t: ^testing.T) {
    source := `(package main)

(defn id [x: int] -> int
  x)

(defn demo [] -> int
  (with-allocator [allocator context.temp_allocator]
    (id 42)))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "context.allocator = allocator"), true)
    testing.expect_value(t, strings.contains(output, "return id(42)"), true)
}

@(test)
compile_final_with_temp_allocator_uses_proc_return_type :: proc(t: ^testing.T) {
    source := `(package main)
(import runtime "base:runtime")

(defn id [x: int] -> int
  x)

(defn demo [] -> int
  (with-temp-allocator [allocator]
    (id 42)))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "runtime.default_temp_allocator_temp_begin()"), true)
    testing.expect_value(t, strings.contains(output, "return id(42)"), true)
}

@(test)
compile_with_temp_allocator_final_scalar_use :: proc(t: ^testing.T) {
    source := `(package main)
(import core "kvist:core")
(import runtime "base:runtime")

(defn total [] -> int
  (with-temp-allocator [allocator]
    (let [xs ([dynamic]int [1 2]) ]
      (defer (delete xs))
      (count xs))))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "runtime.default_temp_allocator_temp_begin"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(xs)"), true)
    testing.expect_value(t, strings.contains(output, "return len(xs)"), true)
}

@(test)
reject_returning_owned_arg_call_from_with_temp_allocator :: proc(t: ^testing.T) {
    source := `(package main)
(import runtime "base:runtime")

(defn pass-through [xs: [dynamic]int] -> [dynamic]int
  xs)

(defn inc [x: int] -> int
  (+ x 1))

(defn bad [xs: []int] -> [dynamic]int
  (with-temp-allocator [allocator]
    (pass-through (arr.map inc xs))))`

    _, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, false)
    defer delete(err.message)
    testing.expect_value(t, err.message, "owned value cannot escape with-temp-allocator; allocate it outside the temp scope or copy it before returning")
}

@(test)
compile_threaded_let_binding_keeps_owned_intermediates_alive :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defstruct User [
  name: string
  active: bool
])

(defn main []
  (let [users ([]User [(User :name "Ada" :active true)
                           (User :name "Lin" :active false)
                           (User :name "Grace" :active true)])
        active-names (->> users
                          (arr.filter .active)
                          (arr.map .name)
                          (arr.take 1))]
    (return)))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "kvist_thread_1 := arr__filter_impl__kvist_field_0_active(type_of(((users)[0:])[0]), (users)[0:])"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(kvist_thread_1)"), true)
    testing.expect_value(t, strings.contains(output, "kvist_thread_2 := (kvist_thread_1)[0:]"), true)
    testing.expect_value(t, strings.contains(output, "kvist_thread_3 := arr__map_impl__kvist_field_0_name(type_of((kvist_thread_2)[0]), type_of((kvist_thread_2)[0].name), kvist_thread_2)"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(kvist_thread_3)"), true)
    testing.expect_value(t, strings.contains(output, "active_names := arr__take(1,"), true)
    testing.expect_value(t, strings.contains(output, "kvist_filter_field_active"), false)
    testing.expect_value(t, strings.contains(output, "kvist_map_field_name"), false)
}

@(test)
allow_returning_owned_sequence_result :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn inc [x: int] -> int
  (+ x 1))

(defn owned [xs: []int] -> [dynamic]int
  (arr.map inc xs))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "return arr__map_impl(inc, (xs)[0:])"), true)
}

@(test)
delete_discarded_owned_sequence_result :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn inc [x: int] -> int
  (+ x 1))

(defn main []
  (let [xs ([]int [1 2 3])]
    (arr.map inc xs)
    (return)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)
    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_thread_"), true)
}

@(test)
warn_discarded_third_party_dynamic_array_result_from_alloc_shape :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "kvist-owned-return-package-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer os.remove_all(dir)
    defer delete(dir)

    pkg_dir, pkg_dir_err := os.join_path({dir, "support"}, context.allocator)
    testing.expect_value(t, pkg_dir_err == nil, true)
    if pkg_dir_err != nil {
        return
    }
    defer delete(pkg_dir)
    mk_pkg_err := os.make_directory_all(pkg_dir)
    testing.expect_value(t, mk_pkg_err == nil, true)
    if mk_pkg_err != nil {
        return
    }

    pkg_path, pkg_path_err := os.join_path({pkg_dir, "support.kvist"}, context.allocator)
    testing.expect_value(t, pkg_path_err == nil, true)
    if pkg_path_err != nil {
        return
    }
    defer delete(pkg_path)
    pkg_source := `(package support)
(import core "kvist:core")

(defn join [xs: []$T, ys: []T] -> [dynamic]T #force_inline
  (let [out (make [dynamic]T 0 (+ (core.count xs) (core.count ys)))]
    (for [x xs]
      (append (addr out) x))
    (for [y ys]
      (append (addr out) y))
    out))`
    pkg_write_err := os.write_entire_file_from_string(pkg_path, pkg_source)
    testing.expect_value(t, pkg_write_err == nil, true)
    if pkg_write_err != nil {
        return
    }

    main_path, main_path_err := os.join_path({dir, "main.kvist"}, context.allocator)
    testing.expect_value(t, main_path_err == nil, true)
    if main_path_err != nil {
        return
    }
    defer delete(main_path)
    main_source := `(package main)
(import support "support")

(defn demo []
  (let [xs ([]int [1])
        ys ([]int [2])]
    (support.join xs ys)
    (return)))`
    main_write_err := os.write_entire_file_from_string(main_path, main_source)
    testing.expect_value(t, main_write_err == nil, true)
    if main_write_err != nil {
        return
    }

    result, err, ok := kvist.compile_path_with_map(main_path)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "support__join :: #force_inline proc(xs: []$T, ys: []T) -> [dynamic]T"), true)
    testing.expect_value(t, strings.contains(result.output, "#owned"), false)
    testing.expect_value(t, strings.contains(result.output, "support__join(xs, ys)"), true)
    testing.expect_value(t, len(result.warnings), 1)
    if len(result.warnings) == 1 {
        testing.expect_value(t, result.warnings[0].message, "owned result from support.join is discarded; bind it and clean it up, or return it")
    }
}

@(test)
compile_read_entire_file_result_lifecycle :: proc(t: ^testing.T) {
    source := `(package main)
(import os "core:os")

(defn read-wrapper [path: string] -> [data: []byte, err: os.Error]
  (os.read_entire_file path context.allocator))

(defn direct-count [path: string] -> int
  (let [[direct-data direct-err] (os.read_entire_file path context.allocator)]
    (if (= direct-err nil) (count direct-data) 0)))

(defn wrapped-count [path: string] -> int
  (let [[wrapped-data wrapped-err] (read-wrapper path)]
    (if (= wrapped-err nil) (count wrapped-data) 0)))

(defn guarded-count [path: string] -> int
  (if-ok [[guarded-data guarded-err] (os.read_entire_file path context.allocator)]
    (count guarded-data)
    0))

(defn guarded-effect [path: string] -> int
  (let [total 0]
    (when-ok [[effect-data effect-err] (os.read_entire_file path context.allocator)]
      (set! total (count effect-data)))
    total))

(defn count-readable [paths: []string] -> int
  (let [total 0]
    (for [path paths]
      (let [[loop-data err] (os.read_entire_file path context.allocator) :or-continue]
        (set! total (+ total (count loop-data)))))
    total))

(defn manual-count [path: string] -> int
  (let [[manual-data manual-err] (os.read_entire_file path context.allocator)]
    (defer (delete manual-data))
    (if (= manual-err nil) (count manual-data) 0)))

(defn transfer-data [path: string] -> []byte
  (let [[transferred-data transferred-err] (os.read_entire_file path context.allocator)]
    transferred-data))

(defn forward-result [path: string] -> [forward-data: []byte, err: os.Error]
  (let [[forward-data err] (os.read_entire_file path context.allocator) :or-return]
    (return forward-data err)))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "defer delete(direct_data)"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(wrapped_data)"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(guarded_data)"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(effect_data)"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(loop_data)"), true)
    testing.expect_value(t, strings.count(output, "defer delete(manual_data)"), 1)
    testing.expect_value(t, strings.contains(output, "delete(transferred_data)"), false)
    testing.expect_value(t, strings.contains(output, "delete(forward_data)"), false)
    testing.expect_value(t, strings.contains(output, "#owned"), false)
    testing.expect_value(t, strings.contains(output, "#borrowed"), false)
}

@(test)
compile_file_handle_result_lifecycle :: proc(t: ^testing.T) {
    source := `(package main)
(import os "core:os")

(defn open-wrapper [path: string] -> [file: ^os.File, err: os.Error]
  (os.open path))

(defn direct-open [path: string] -> bool
  (let [[direct-file direct-err] (os.open path)]
    (and (= direct-err nil) (!= direct-file nil))))

(defn wrapped-open [path: string] -> bool
  (let [[wrapped-file wrapped-err] (open-wrapper path)]
    (and (= wrapped-err nil) (!= wrapped-file nil))))

(defn create-file [path: string] -> bool
  (let [[created-file created-err] (os.create path)]
    (and (= created-err nil) (!= created-file nil))))

(defn clone-file [original: ^os.File] -> bool
  (let [[cloned-file cloned-err] (os.clone original)]
    (and (= cloned-err nil) (!= cloned-file nil))))

(defn manual-open [path: string] -> bool
  (let [[manual-file manual-err] (os.open path)]
    (defer (os.close manual-file))
    (and (= manual-err nil) (!= manual-file nil))))

(defn transfer-file [path: string] -> ^os.File
  (let [[transferred-file transferred-err] (os.open path)]
    transferred-file))

(defn forward-file [path: string] -> [file: ^os.File, err: os.Error]
  (let [[file err] (os.open path) :or-return]
    (return file err)))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "if direct_err == nil"), true)
    testing.expect_value(t, strings.contains(output, "os.close(direct_file)"), true)
    testing.expect_value(t, strings.contains(output, "if wrapped_err == nil"), true)
    testing.expect_value(t, strings.contains(output, "os.close(wrapped_file)"), true)
    testing.expect_value(t, strings.contains(output, "if created_err == nil"), true)
    testing.expect_value(t, strings.contains(output, "os.close(created_file)"), true)
    testing.expect_value(t, strings.contains(output, "if cloned_err == nil"), true)
    testing.expect_value(t, strings.contains(output, "os.close(cloned_file)"), true)
    testing.expect_value(t, strings.count(output, "defer os.close(manual_file)"), 1)
    testing.expect_value(t, strings.contains(output, "os.close(transferred_file)"), false)
    testing.expect_value(t, strings.contains(output, "os.close(file)"), false)
    testing.expect_value(t, strings.contains(output, "#owned"), false)
    testing.expect_value(t, strings.contains(output, "#borrowed"), false)
}

@(test)
warn_when_automatic_file_cleanup_is_skipped_for_capture :: proc(t: ^testing.T) {
    source := `(package main)
(import os "core:os")

(defn apply-check [f: (fn [] -> bool)] -> bool
  (f))

(defn captured-open [path: string] -> bool
  (let [[captured-file captured-err] (os.open path)]
    (if (= captured-err nil)
      (apply-check (fn [] -> bool (!= captured-file nil)))
      false)))

(defn shadowed-open [path: string] -> bool
  (let [[shadowed-file shadowed-err] (os.open path)]
    (if (= shadowed-err nil)
      (let [shadowed-file 42]
        (apply-check (fn [] -> bool (= shadowed-file 42))))
      false)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "os.close(captured_file)"), false)
    testing.expect_value(t, strings.contains(result.output, "proc(captured_file: ^os.File) -> bool"), true)
    testing.expect_value(t, strings.contains(result.output, "os.close(shadowed_file)"), true)
    testing.expect_value(t, len(result.warnings), 1)
    if len(result.warnings) == 1 {
        testing.expect_value(t, result.warnings[0].message, "automatic cleanup for owned result `captured_file` was skipped because it is captured by a closure; clean it up explicitly after its last use or transfer ownership")
        testing.expect_value(t, result.warnings[0].code, kvist.Compile_Warning_Code.Ownership_Automatic_Cleanup_Skipped)
        testing.expect_value(t, result.warnings[0].confidence, kvist.Compile_Warning_Confidence.Conservative)
    }
}

@(test)
warn_when_automatic_file_cleanup_is_skipped_for_storage :: proc(t: ^testing.T) {
    source := `(package main)
(import os "core:os")

(defstruct File-Holder [file: ^os.File])

(defn stored-open [path: string] -> bool
  (let [[stored-file stored-err] (os.open path)]
    (if (= stored-err nil)
      (let [holder (File-Holder :file stored-file)]
        (!= holder.file nil))
      false)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "os.close(stored_file)"), false)
    testing.expect_value(t, len(result.warnings), 1)
    if len(result.warnings) == 1 {
        testing.expect_value(t, result.warnings[0].message, "automatic cleanup for owned result `stored_file` was skipped because it is stored in an aggregate or mutable place; clean it up explicitly after its last use or transfer ownership")
        testing.expect_value(t, result.warnings[0].code, kvist.Compile_Warning_Code.Ownership_Automatic_Cleanup_Skipped)
        testing.expect_value(t, result.warnings[0].confidence, kvist.Compile_Warning_Confidence.Conservative)
    }
}

@(test)
clean_discarded_direct_read_entire_file :: proc(t: ^testing.T) {
    source := `(package main)
(import os "core:os")

(defn discarded [path: string]
  (os.read_entire_file path context.allocator)
  (return))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "kvist_thread_1, _ := os.read_entire_file"), true)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_thread_1)"), true)
}

@(test)
clean_discarded_third_party_named_owned_bytes_from_alloc_shape :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "kvist-owned-named-bytes-package-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer os.remove_all(dir)
    defer delete(dir)

    pkg_dir, pkg_dir_err := os.join_path({dir, "support"}, context.allocator)
    testing.expect_value(t, pkg_dir_err == nil, true)
    if pkg_dir_err != nil {
        return
    }
    defer delete(pkg_dir)
    mk_pkg_err := os.make_directory_all(pkg_dir)
    testing.expect_value(t, mk_pkg_err == nil, true)
    if mk_pkg_err != nil {
        return
    }

    pkg_path, pkg_path_err := os.join_path({pkg_dir, "support.kvist"}, context.allocator)
    testing.expect_value(t, pkg_path_err == nil, true)
    if pkg_path_err != nil {
        return
    }
    defer delete(pkg_path)
    pkg_source := `(package support)
(import ops "core:os")

(defn read-bytes [path: string] -> [data: []byte, err: ops.Error] #force_inline
  (ops.read_entire_file path context.allocator))`
    pkg_write_err := os.write_entire_file_from_string(pkg_path, pkg_source)
    testing.expect_value(t, pkg_write_err == nil, true)
    if pkg_write_err != nil {
        return
    }

    main_path, main_path_err := os.join_path({dir, "main.kvist"}, context.allocator)
    testing.expect_value(t, main_path_err == nil, true)
    if main_path_err != nil {
        return
    }
    defer delete(main_path)
    main_source := `(package main)
(import support "support")

(defn main [path: string]
  (support.read-bytes path)
  (return))`
    main_write_err := os.write_entire_file_from_string(main_path, main_source)
    testing.expect_value(t, main_write_err == nil, true)
    if main_write_err != nil {
        return
    }

    result, err, ok := kvist.compile_path_with_map(main_path)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "support__read_bytes :: #force_inline proc(path: string) -> (data: []byte, err: ops.Error)"), true)
    testing.expect_value(t, strings.contains(result.output, "#owned"), false)
    testing.expect_value(t, strings.contains(result.output, "return ops.read_entire_file(path, context.allocator)"), true)
    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "kvist_thread_1, _ := support__read_bytes"), true)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_thread_1)"), true)
}

@(test)
delete_discarded_third_party_destructured_owned_wrapper_result :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "kvist-owned-destructured-wrapper-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer os.remove_all(dir)
    defer delete(dir)

    pkg_dir, pkg_dir_err := os.join_path({dir, "support"}, context.allocator)
    testing.expect_value(t, pkg_dir_err == nil, true)
    if pkg_dir_err != nil {
        return
    }
    defer delete(pkg_dir)
    mk_pkg_err := os.make_directory_all(pkg_dir)
    testing.expect_value(t, mk_pkg_err == nil, true)
    if mk_pkg_err != nil {
        return
    }

    pkg_path, pkg_path_err := os.join_path({pkg_dir, "support.kvist"}, context.allocator)
    testing.expect_value(t, pkg_path_err == nil, true)
    if pkg_path_err != nil {
        return
    }
    defer delete(pkg_path)
    pkg_source := `(package support)
(import os "core:os")

(defn read-base [path: string] -> [data: []byte, err: os.Error] #force_inline
  (os.read_entire_file path context.allocator))

(defn read-wrapper [path: string] -> []byte #force_inline
  (let [[data err] (read-base path)]
    data))`
    pkg_write_err := os.write_entire_file_from_string(pkg_path, pkg_source)
    testing.expect_value(t, pkg_write_err == nil, true)
    if pkg_write_err != nil {
        return
    }

    main_path, main_path_err := os.join_path({dir, "main.kvist"}, context.allocator)
    testing.expect_value(t, main_path_err == nil, true)
    if main_path_err != nil {
        return
    }
    defer delete(main_path)
    main_source := `(package main)
(import support "support")

(defn main [path: string]
  (support.read-wrapper path)
  (return))`
    main_write_err := os.write_entire_file_from_string(main_path, main_source)
    testing.expect_value(t, main_write_err == nil, true)
    if main_write_err != nil {
        return
    }

    result, err, ok := kvist.compile_path_with_map(main_path)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "support__read_base :: #force_inline proc(path: string) -> (data: []byte, err: os.Error)"), true)
    testing.expect_value(t, strings.contains(result.output, "support__read_wrapper :: #force_inline proc(path: string) -> []byte"), true)
    testing.expect_value(t, strings.contains(result.output, "#owned"), false)
    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_thread_"), true)
}

@(test)
compile_direct_core_strings_result_without_owned_warning :: proc(t: ^testing.T) {
    source := `(package main)
(import strings "core:strings")

(defn main [s: string]
  (strings.clone s)
  (return))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
}

@(test)
delete_discarded_third_party_replaced_string_from_alloc_shape :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "kvist-source-owned-replace-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer os.remove_all(dir)
    defer delete(dir)

    pkg_dir, pkg_dir_err := os.join_path({dir, "support"}, context.allocator)
    testing.expect_value(t, pkg_dir_err == nil, true)
    if pkg_dir_err != nil {
        return
    }
    defer delete(pkg_dir)
    mk_pkg_err := os.make_directory_all(pkg_dir)
    testing.expect_value(t, mk_pkg_err == nil, true)
    if mk_pkg_err != nil {
        return
    }

    pkg_path, pkg_path_err := os.join_path({pkg_dir, "support.kvist"}, context.allocator)
    testing.expect_value(t, pkg_path_err == nil, true)
    if pkg_path_err != nil {
        return
    }
    defer delete(pkg_path)
    pkg_source := `(package support)
(import strings "core:strings")

(defn replace-all [s: string, old: string, new: string] -> string #force_inline
  (let [[out _] (strings.replace s old new -1)]
    out))`
    pkg_write_err := os.write_entire_file_from_string(pkg_path, pkg_source)
    testing.expect_value(t, pkg_write_err == nil, true)
    if pkg_write_err != nil {
        return
    }

    main_path, main_path_err := os.join_path({dir, "main.kvist"}, context.allocator)
    testing.expect_value(t, main_path_err == nil, true)
    if main_path_err != nil {
        return
    }
    defer delete(main_path)
    main_source := `(package main)
(import support "support")

(defn main [s: string]
  (support.replace-all s "x" "y")
  (return))`
    main_write_err := os.write_entire_file_from_string(main_path, main_source)
    testing.expect_value(t, main_write_err == nil, true)
    if main_write_err != nil {
        return
    }

    result, err, ok := kvist.compile_path_with_map(main_path)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "support__replace_all :: #force_inline proc(s, old, new: string) -> string"), true)
    testing.expect_value(t, strings.contains(result.output, "out, _ := strings.replace(s, old, new, -1)"), true)
    testing.expect_value(t, strings.contains(result.output, "#owned"), false)
    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_thread_"), true)
}

@(test)
reject_nested_owned_sequence_result :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn inc [x: int] -> int
  (+ x 1))

(defn bad [xs: []int] -> int
  (arr.first (arr.map inc xs)))`

    _, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, false)
    defer delete(err.message)
    testing.expect_value(t, err.message, "arr.map returns an owned result; bind it so it can be cleaned up, or return it to transfer ownership")
}

@(test)
reject_nested_tapped_owned_sequence_result :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn inc [x: int] -> int
  (+ x 1))

(defn bad [xs: []int] -> int
  (arr.first (tap> "mapped" (arr.map inc xs))))`

    _, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, false)
    defer delete(err.message)
    testing.expect_value(t, err.message, "arr.map returns an owned result; bind it so it can be cleaned up, or return it to transfer ownership")
}

@(test)
compile_multiline_statement_odin_escape :: proc(t: ^testing.T) {
    source := `(package main)

(defn main []
  (odin "x := 1\n_ = x")
  (return))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    expected := `package main

main :: proc() {
    x := 1
    _ = x
    return
}
`
    testing.expect_value(t, output, expected)
}

@(test)
compile_automatically_cleans_up_untransferred_owned_let_local :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn demo []
  (let [xs (arr.empty int)]
    (println 1)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, result.ownership_plan_adoptions, 1)
    testing.expect_value(t, strings.contains(result.output, "defer (proc(kvist_place: ^[dynamic]int, kvist_owner: ^bool)"), true)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_place^)"), true)
}

@(test)
compile_automatically_cleans_up_untransferred_owned_string_local :: proc(t: ^testing.T) {
    source := `(package main)

(defn make-label [value: int] -> string
  (str "value=" value))

(defn demo [] -> int
  (let [label (make-label 42)]
    (count label)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "defer (proc(kvist_place: ^string, kvist_owner: ^bool)"), true)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_place^)"), true)
}

@(test)
compile_automatically_cleans_up_untransferred_owned_slice_local :: proc(t: ^testing.T) {
    source := `(package main)
(import strings "core:strings")

(defn split-words [value: string] -> []string
  (strings.split value " "))

(defn demo [value: string] -> int
  (let [words (split-words value)]
    (count words)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "defer (proc(kvist_place: ^[]string, kvist_owner: ^bool)"), true)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_place^)"), true)
}

@(test)
compile_does_not_warn_for_typed_non_owned_aggregate_let_local :: proc(t: ^testing.T) {
    source := `(package main)
(import rl "vendor:raylib")

(defn demo []
  (let [player-pos: rl.Vector2 [0 0]
        player-vel: rl.Vector2 [0 0]
        player-grounded? false
        player-flip? false]
    (discard player-pos player-vel player-grounded? player-flip?)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
}

@(test)
compile_tracks_owned_replacement_after_delete_and_set :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn demo []
  (let [xs (arr.empty int)
        replacement (arr.empty int)]
    (delete xs)
    (set! xs replacement)
    (println (count xs))
    (delete xs)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
}

@(test)
delete_discarded_third_party_split_slice_from_alloc_shape :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "kvist-source-owned-split-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer os.remove_all(dir)
    defer delete(dir)

    pkg_dir, pkg_dir_err := os.join_path({dir, "support"}, context.allocator)
    testing.expect_value(t, pkg_dir_err == nil, true)
    if pkg_dir_err != nil {
        return
    }
    defer delete(pkg_dir)
    mk_pkg_err := os.make_directory_all(pkg_dir)
    testing.expect_value(t, mk_pkg_err == nil, true)
    if mk_pkg_err != nil {
        return
    }

    pkg_path, pkg_path_err := os.join_path({pkg_dir, "support.kvist"}, context.allocator)
    testing.expect_value(t, pkg_path_err == nil, true)
    if pkg_path_err != nil {
        return
    }
    defer delete(pkg_path)
    pkg_source := `(package support)
(import strings "core:strings")

(defn split-words [s: string] -> []string #force_inline
  (strings.split s " "))`
    pkg_write_err := os.write_entire_file_from_string(pkg_path, pkg_source)
    testing.expect_value(t, pkg_write_err == nil, true)
    if pkg_write_err != nil {
        return
    }

    main_path, main_path_err := os.join_path({dir, "main.kvist"}, context.allocator)
    testing.expect_value(t, main_path_err == nil, true)
    if main_path_err != nil {
        return
    }
    defer delete(main_path)
    main_source := `(package main)
(import support "support")

(defn main [s: string]
  (support.split-words s)
  (return))`
    main_write_err := os.write_entire_file_from_string(main_path, main_source)
    testing.expect_value(t, main_write_err == nil, true)
    if main_write_err != nil {
        return
    }

    result, err, ok := kvist.compile_path_with_map(main_path)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "support__split_words :: #force_inline proc(s: string) -> []string"), true)
    testing.expect_value(t, strings.contains(result.output, "return strings.split(s, \" \")"), true)
    testing.expect_value(t, strings.contains(result.output, "#owned"), false)
    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_thread_"), true)
}

@(test)
conditional_owned_struct_results_keep_their_field_cleanup :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defstruct Payload [left: string right: string marker: int])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn make-payload [marker: int] -> Payload
  (Payload
    :left (clone-string "left")
    :right (clone-string "right")
    :marker marker))

(defn delete-payload [payload: Payload]
  (delete payload.left)
  (delete payload.right))

(defn clean [flag: bool] -> int
  (let [payload (if flag (make-payload 1) (make-payload 2))]
    payload.marker))

(defn transfer [flag: bool] -> int
  (let [payload (if flag (make-payload 1) (make-payload 2))
        moved payload :defer-with delete-payload]
    moved.marker))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(payload.left)"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(payload.right)"),
        true,
    )
    transfer_start := strings.index(result.output, "transfer :: proc")
    testing.expect(t, transfer_start >= 0)
    if transfer_start >= 0 {
        transfer_output := result.output[transfer_start:]
        testing.expect_value(
            t,
            strings.contains(transfer_output, "defer delete(payload.left)"),
            false,
        )
        testing.expect_value(
            t,
            strings.contains(transfer_output, "defer delete(payload.right)"),
            false,
        )
        testing.expect_value(
            t,
            strings.contains(transfer_output, "defer delete_payload(moved)"),
            true,
        )
    }
}

@(test)
owned_struct_payloads_transfer_into_named_and_positional_unions :: proc(
    t: ^testing.T,
) {
    source := `(package app)
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

(defn named [] -> int
  (let [text (clone-string "named")
        owned (Owned :text text)
        choice (Choice :owned owned) :defer-with delete-choice]
    (case choice (Owned value) (count value.text) 0)))

(defn positional [] -> int
  (let [text (clone-string "positional")
        owned (Owned text)
        choice (Choice owned) :defer-with delete-choice]
    (case choice (Owned value) (count value.text) 0)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(owned.text)"),
        false,
    )
    testing.expect_value(
        t,
        strings.count(result.output, "defer delete_choice(choice)"),
        2,
    )
}

@(test)
owned_string_payloads_transfer_into_named_and_positional_unions :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defunion Choice [text: string values: [dynamic]int raw: int])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn delete-choice [choice: Choice]
  (case choice
    (string value) (delete value)
    ([dynamic]int values) (delete values)
    (int _) (discard 0)
    (discard 0)))

(defn named [] -> int
  (let [text (clone-string "named")
        choice (Choice :text text) :defer-with delete-choice]
    (case choice (string value) (count value) 0)))

(defn positional [] -> int
  (let [text (clone-string "positional")
        choice (Choice text) :defer-with delete-choice]
    (case choice (string value) (count value) 0)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(result.output, "defer delete(text)"),
        false,
    )
    testing.expect_value(
        t,
        strings.count(result.output, "defer delete_choice(choice)"),
        2,
    )
}

@(test)
direct_owned_struct_fields_are_cleaned_and_overwrites_are_diagnosed :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defstruct Owned [text: string])
(defstruct Inner [text: string])
(defstruct Outer [inner: Inner marker: int])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn clean [] -> int
  (let [owned (Owned :text (clone-string "owned"))]
    (count owned.text)))

(defn clean-nested [] -> int
  (let [outer (Outer
                :inner (Inner :text (clone-string "nested"))
                :marker 1)]
    (count outer.inner.text)))

(defn make-nested [] -> Outer
  (Outer
    :inner (Inner :text (clone-string "returned"))
    :marker 2))

(defn clean-returned-nested [] -> int
  (let [outer (make-nested)]
    (count outer.inner.text)))

(defn replace [] -> int
  (let [owned (Owned :text (clone-string "first"))]
    (set! owned.text (clone-string "second"))
    (count owned.text)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 1)
    if len(result.warnings) == 1 {
        testing.expect_value(
            t,
            result.warnings[0].code,
            kvist.Compile_Warning_Code.Ownership_Overwrite,
        )
        testing.expect_value(
            t,
            result.warnings[0].confidence,
            kvist.Compile_Warning_Confidence.Definite,
        )
    }
    clean_start := strings.index(result.output, "clean :: proc")
    replace_start := strings.index(result.output, "replace :: proc")
    testing.expect(t, clean_start >= 0 && replace_start > clean_start)
    if clean_start >= 0 && replace_start > clean_start {
        clean_output := result.output[clean_start:replace_start]
        testing.expect_value(
            t,
            strings.contains(clean_output, "defer delete(owned.text)"),
            true,
        )
        testing.expect_value(
            t,
            strings.count(clean_output, "defer delete(outer.inner.text)"),
            2,
        )
    }
}

@(test)
mixed_local_struct_field_ownership_emits_precise_kvo008 :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defstruct Owned [text: string])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn use [owned?: bool] -> int
  (let [value (Owned :text (if owned? (clone-string "owned") "borrowed"))]
    (count value.text)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 1)
    if len(result.warnings) == 1 {
        testing.expect_value(
            t,
            result.warnings[0].code,
            kvist.Compile_Warning_Code.Ownership_Automatic_Cleanup_Skipped,
        )
        testing.expect_value(
            t,
            result.warnings[0].confidence,
            kvist.Compile_Warning_Confidence.Conservative,
        )
        testing.expect_value(
            t,
            strings.contains(result.warnings[0].message, "`value.text`"),
            true,
        )
        warning_span := result.warnings[0].span
        testing.expect(
            t,
            warning_span.start >= 0 && warning_span.end <= len(source),
        )
        if warning_span.start >= 0 && warning_span.end <= len(source) {
            testing.expect_value(
                t,
                source[warning_span.start:warning_span.end],
                `(if owned? (clone-string "owned") "borrowed")`,
            )
        }
    }
}

@(test)
mixed_scalar_field_return_emits_precise_kvo008 :: proc(t: ^testing.T) {
    source := `(package app)
(import strings "core:strings")

(defstruct Leaf [text: string])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn maybe-text [owned?: bool] -> string
  (let [leaf (Leaf :text (clone-string "owned"))]
    (if owned? leaf.text "borrowed")))

(defn use [owned?: bool] -> int
  (let [value (maybe-text owned?)]
    (count value)))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 1)
    if len(result.warnings) == 1 {
        warning := result.warnings[0]
        testing.expect_value(
            t,
            warning.code,
            kvist.Compile_Warning_Code.Ownership_Automatic_Cleanup_Skipped,
        )
        testing.expect_value(
            t,
            warning.confidence,
            kvist.Compile_Warning_Confidence.Conservative,
        )
        testing.expect_value(
            t,
            strings.contains(warning.message, "result from maybe-text"),
            true,
        )
        testing.expect(
            t,
            warning.span.start >= 0 && warning.span.end <= len(source),
        )
        if warning.span.start >= 0 && warning.span.end <= len(source) {
            testing.expect_value(
                t,
                source[warning.span.start:warning.span.end],
                `(maybe-text owned?)`,
            )
        }
    }
}

@(test)
warn_when_direct_field_result_ownership_differs_by_branch :: proc(
    t: ^testing.T,
) {
    source := `(package app)
(import strings "core:strings")

(defstruct Leaf [text: string])
(defstruct Inner [left: string right: string])
(defstruct Outer [inner: Inner])

(defn clone-string [value: string] -> string
  (let [[result error] (strings.clone value)]
    (assert (= error nil))
    result))

(defn maybe-leaf [owned?: bool] -> Leaf
  (Leaf :text (if owned? (clone-string "owned") "borrowed")))

(defn use [owned?: bool] -> int
  (let [leaf (maybe-leaf owned?)]
    (count leaf.text)))

(defn maybe-outer [] -> Outer
  (Outer :inner (Inner
                  :left (clone-string "owned")
                  :right "borrowed")))

(defn use-outer [] -> int
  (let [outer (maybe-outer)]
    (+ (count outer.inner.left) (count outer.inner.right))))`
    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 2)
    for warning in result.warnings {
        testing.expect_value(
            t,
            warning.code,
            kvist.Compile_Warning_Code.Ownership_Automatic_Cleanup_Skipped,
        )
        testing.expect_value(
            t,
            warning.confidence,
            kvist.Compile_Warning_Confidence.Conservative,
        )
    }
}
