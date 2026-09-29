package tests

import "base:runtime"
import fmt "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import kvist "../src/odin/kvist"

@(test)
compile_direct_dynamic_array_expr_borrows_as_slice_argument :: proc(t: ^testing.T) {
    source := `(package main)

(defn total [xs: []int] -> int
  (count xs))

(defn demo [] -> int
  (total ([dynamic]int [1 2 3])))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "kvist_thread_1 := [dynamic]int{1, 2, 3}"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(kvist_thread_1)"), true)
    testing.expect_value(t, strings.contains(output, "return total(kvist_thread_1)"), true)
}

@(test)
compile_dynamic_array_local_borrows_as_slice_argument :: proc(t: ^testing.T) {
    source := `(package main)

(defstruct Order [
  amount: int
])

(defn total [orders: []Order] -> int
  (let [sum 0]
    (for [order orders]
      (mut! sum += order.amount))
    sum))

(defn main []
  (let [orders [(Order :amount 120)
                (Order :amount 80)] :defer]
    (println (total orders))))`

    output, err, ok := kvist.compile_source(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(output)

    testing.expect_value(t, strings.contains(output, "orders := [dynamic]Order{Order{amount = 120}, Order{amount = 80}}"), true)
    testing.expect_value(t, strings.contains(output, "defer delete(orders)"), true)
    testing.expect_value(t, strings.contains(output, "fmt.println(total((orders)[:]))"), true)
}

@(test)
reject_returning_threaded_view_of_owned_intermediate :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defstruct User [
  name: string
  active: bool
])

(defn bad [users: []User] -> []string
  (let [active-names (->> users
                          (arr.filter .active)
                          (arr.map .name)
                          (arr.take 1))]
    active-names))`

    _, err, ok := kvist.compile_source(source)
    defer delete(err.message)
    testing.expect_value(t, ok, false)
    testing.expect_value(t, err.message, "cannot return a borrowed view that depends on an owned intermediate; return an owned result or keep the pipeline local")
}

@(test)
delete_owned_and_warn_borrowed_third_party_odin_string_alias_results :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "kvist-source-odin-string-alias-*", context.allocator)
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
(import s "core:strings")

(defn lower-copy [value: string] -> string #force_inline
  (s.to_lower value))

(defn trim-view [value: string] -> string #force_inline
  (s.trim_space value))`
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

(defn main [value: string]
  (support.lower-copy value)
  (let [view (support.trim-view value) :defer]
    (println view))
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

    testing.expect_value(t, strings.contains(result.output, "support__lower_copy :: #force_inline proc(value: string) -> string"), true)
    testing.expect_value(t, strings.contains(result.output, "return s.to_lower(value)"), true)
    testing.expect_value(t, strings.contains(result.output, "support__trim_view :: #force_inline proc(value: string) -> string"), true)
    testing.expect_value(t, strings.contains(result.output, "return s.trim_space(value)"), true)
    testing.expect_value(t, strings.contains(result.output, "#owned"), false)
    testing.expect_value(t, strings.contains(result.output, "#borrowed"), false)
    testing.expect_value(t, strings.contains(result.output, "delete(kvist_thread_"), true)
    testing.expect_value(t, len(result.warnings), 1)
    if len(result.warnings) == 1 {
        testing.expect_value(t, result.warnings[0].message, "support.trim-view returns a borrowed view; do not delete it, delete the owner instead")
    }
}

@(test)
compile_warns_when_deleting_direct_and_provenance_tracked_borrows :: proc(t: ^testing.T) {
    source := `(package main)
(import str "kvist:str")

(defn demo [s: string, flag?: bool]
  (delete (str.trim s))
  (let [view (str.trim s)]
    (delete view))
  (let [maybe-view s]
    (if flag?
      (set! maybe-view (str.trim s))
      (println 0))
    (delete maybe-view)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 3)
    if len(result.warnings) == 3 {
        for warning in result.warnings {
            testing.expect_value(
                t,
                warning.code,
                kvist.Compile_Warning_Code.Ownership_Delete_Borrowed,
            )
        }
        testing.expect_value(
            t,
            result.warnings[0].message,
            "str.trim returns a borrowed view; do not delete it, delete the owner instead",
        )
        testing.expect_value(
            t,
            result.warnings[0].confidence,
            kvist.Compile_Warning_Confidence.Definite,
        )
        testing.expect_value(
            t,
            result.warnings[1].message,
            "borrowed local `view` must not be deleted; delete the owner instead",
        )
        testing.expect_value(
            t,
            result.warnings[1].confidence,
            kvist.Compile_Warning_Confidence.Definite,
        )
        testing.expect_value(
            t,
            result.warnings[2].message,
            "borrowed local `maybe_view` must not be deleted; delete the owner instead",
        )
        testing.expect_value(
            t,
            result.warnings[2].confidence,
            kvist.Compile_Warning_Confidence.Conservative,
        )
    }
}

@(test)
compile_knows_borrow_is_definite_when_branches_choose_different_owners :: proc(t: ^testing.T) {
    source := `(package main)
(import str "kvist:str")

(defn demo [flag?: bool]
  (let [left (str.lower "LEFT") :defer
        right (str.lower "RIGHT") :defer
        view: string ""]
    (if flag?
      (set! view (str.trim left))
      (set! view (str.trim right)))
    (delete view)))`

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
            kvist.Compile_Warning_Code.Ownership_Delete_Borrowed,
        )
        testing.expect_value(
            t,
            result.warnings[0].confidence,
            kvist.Compile_Warning_Confidence.Definite,
        )
        testing.expect_value(
            t,
            result.warnings[0].message,
            "borrowed local `view` must not be deleted; delete the owner instead",
        )
    }
}

@(test)
compile_does_not_keep_borrowed_local_after_owned_reassignment :: proc(t: ^testing.T) {
    source := `(package main)
(import strings "core:strings")

(defn lower-after-view [s: string] -> string
  (let [view (strings.trim_space s)]
    (set! view (strings.to_lower view))
    view))

(defn main [s: string]
  (let [owned (lower-after-view s) :defer]
    (println owned)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "#borrowed"), false)
    testing.expect_value(t, strings.contains(result.output, "#owned"), false)
    testing.expect_value(t, len(result.warnings), 0)
}

@(test)
compile_warns_for_borrowed_value_escaping_owner :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn bad-view [] -> []int
  (let [xs (arr.range 0 10) :defer]
    (arr.slice xs 0 3)))`

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
        testing.expect_value(t, result.warnings[0].message, "borrowed value escapes owner `xs`; `xs` is released when this scope exits, so the borrowed value may become invalid; return an owned copy or keep the value within the owner's lifetime")
    }
}

@(test)
compile_warns_for_bound_borrowed_value_escaping_owner :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn bad-view [] -> []int
  (let [xs (arr.range 0 10) :defer
        view (arr.slice xs 0 3)]
    view))`

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
        testing.expect_value(t, result.warnings[0].message, "borrowed value escapes owner `xs`; `xs` is released when this scope exits, so the borrowed value may become invalid; return an owned copy or keep the value within the owner's lifetime")
    }
}

@(test)
compile_warns_only_when_destroyed_owner_borrow_is_used :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn definite []
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)]
    (delete xs)
    (println (count view))))

(defn conditional [destroy?: bool]
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)]
    (if destroy?
      (delete xs)
      (println 0))
    (println (count view))))

(defn transitive []
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)
        nested (arr.slice view 0 0)]
    (delete xs)
    (println (count nested))))

(defn late-alias []
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)]
    (delete xs)
    (let [alias view]
      (println (count alias)))))

(defn returned [] -> []int
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)]
    (delete xs)
    view))

(defn unused []
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)]
    (delete xs)
    (println 0)))

(defn reassigned []
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)]
    (delete xs)
    (set! view ([]int []))
    (println (count view))))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 5)
    if len(result.warnings) == 5 {
        for warning in result.warnings {
            testing.expect_value(
                t,
                warning.code,
                kvist.Compile_Warning_Code.Ownership_Borrowed_Escape,
            )
            testing.expect_value(
                t,
                strings.contains(
                    warning.message,
                    "borrowed value is used after owner `xs`",
                ),
                true,
            )
        }
        testing.expect_value(
            t,
            result.warnings[0].confidence,
            kvist.Compile_Warning_Confidence.Definite,
        )
        testing.expect_value(
            t,
            result.warnings[0].message,
            "borrowed value is used after owner `xs` has been destroyed; move the use before cleanup or create an owned copy",
        )
        testing.expect_value(
            t,
            result.warnings[1].confidence,
            kvist.Compile_Warning_Confidence.Conservative,
        )
        testing.expect_value(
            t,
            result.warnings[1].message,
            "borrowed value is used after owner `xs` may have been destroyed; move the use before cleanup or create an owned copy",
        )
        testing.expect_value(
            t,
            result.warnings[2].confidence,
            kvist.Compile_Warning_Confidence.Definite,
        )
        testing.expect_value(
            t,
            result.warnings[3].confidence,
            kvist.Compile_Warning_Confidence.Definite,
        )
        testing.expect_value(
            t,
            result.warnings[4].confidence,
            kvist.Compile_Warning_Confidence.Definite,
        )
    }
}

@(test)
compile_tracks_destroyed_borrowers_through_loops_scopes_and_custom_cleanup :: proc(
    t: ^testing.T,
) {
    source := `(package main)
(import arr "kvist:arr")

(defn release-array [xs: [dynamic]int]
  (delete xs))

(defn definite-loop []
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)]
    (while true
      (delete xs)
      (break))
    (println (count view))))

(defn conditional-loop [run?: bool]
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)]
    (while run?
      (delete xs)
      (set! run? false))
    (println (count view))))

(defn nested-scope []
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)]
    (block
      (delete xs))
    (println (count view))))

(defn custom-cleanup []
  (let [xs (arr.empty int)
        view (arr.slice xs 0 0)]
    (release-array xs)
    (println (count view))))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    expected_confidence := [4]kvist.Compile_Warning_Confidence{
        .Conservative,
        .Conservative,
        .Definite,
        .Definite,
    }
    borrow_warning_count := 0
    transfer_warning_count := 0
    for warning in result.warnings {
        if warning.code == .Ownership_Use_After_Transfer {
            transfer_warning_count += 1
            continue
        }
        if warning.code == .Ownership_Borrowed_Escape {
            testing.expect_value(
                t,
                borrow_warning_count < len(expected_confidence),
                true,
            )
            if borrow_warning_count < len(expected_confidence) {
                testing.expect_value(
                    t,
                    warning.confidence,
                    expected_confidence[borrow_warning_count],
                )
            }
            testing.expect_value(
                t,
                strings.contains(
                    warning.message,
                    "borrowed value is used after owner `xs`",
                ),
                true,
            )
            borrow_warning_count += 1
        }
    }
    testing.expect_value(t, borrow_warning_count, 4)
    // The conditional loop can execute again in the CFG after destroying xs,
    // so the existing owner-liveness analysis also reports KVO003.
    testing.expect_value(t, transfer_warning_count, 1)
}

@(test)
compile_warns_for_transitively_borrowed_value_escaping_owner :: proc(
    t: ^testing.T,
) {
    source := `(package main)
(import arr "kvist:arr")

(defn bad-view [] -> []int
  (let [xs (arr.range 0 10) :defer
        first (arr.slice xs 0 5)
        second (arr.slice first 0 3)]
    second))`

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
            result.warnings[0].message,
            "borrowed value escapes owner `xs`; `xs` is released when this scope exits, so the borrowed value may become invalid; return an owned copy or keep the value within the owner's lifetime",
        )
    }
}

@(test)
compile_warns_for_borrowed_value_escaping_in_returned_composite :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defstruct ViewBox [
  view: []int
])

(defn bad-view [] -> ViewBox
  (let [xs (arr.range 0 10) :defer
        view (arr.slice xs 0 3)]
    (ViewBox :view view)))`

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
        testing.expect_value(t, result.warnings[0].message, "borrowed value escapes owner `xs`; `xs` is released when this scope exits, so the borrowed value may become invalid; return an owned copy or keep the value within the owner's lifetime")
    }
}

@(test)
compile_warns_when_borrow_crosses_inner_owner_scope_boundaries :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn fallthrough-view []
  (let [view: []int ([]int [])]
    (let [fallthrough-owner (arr.range 0 10) :defer]
      (set! view (arr.slice fallthrough-owner 0 3)))
    (println (count view))))

(defn break-view []
  (let [view: []int ([]int [])]
    (while true
      (let [break-owner (arr.range 0 10) :defer]
        (set! view (arr.slice break-owner 0 3))
        (break)))
    (println (count view))))

(defn continue-view [run?: bool]
  (let [view: []int ([]int [])]
    (while run?
      (let [continue-owner (arr.range 0 10) :defer]
        (set! view (arr.slice continue-owner 0 3))
        (set! run? false)
        (continue)))
    (println (count view))))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, len(result.warnings), 3)
    if len(result.warnings) == 3 {
        expected_owners := [3]string{
            "fallthrough_owner",
            "break_owner",
            "continue_owner",
        }
        for warning, index in result.warnings {
            testing.expect_value(
                t,
                warning.code,
                kvist.Compile_Warning_Code.Ownership_Borrowed_Escape,
            )
            testing.expect_value(
                t,
                warning.confidence,
                kvist.Compile_Warning_Confidence.Conservative,
            )
            testing.expect_value(
                t,
                strings.contains(warning.message, expected_owners[index]),
                true,
            )
        }
    }
}

@(test)
compile_warns_for_third_party_conditional_borrowed_assignment_escaping_owner :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "kvist-borrowed-escape-branch-set-*", context.allocator)
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

(defn left [xs: []int] -> []int #force_inline
  (slice xs 0 2))

(defn right [xs: []int] -> []int #force_inline
  (slice xs 1 3))`
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
(import arr "kvist:arr")
(import support "support")

(defn bad-view [flag?: bool] -> []int
  (let [xs (arr.range 0 10) :defer
        view: []int ([]int [])]
    (if flag?
      (set! view (support.left xs))
      (set! view (support.right xs)))
    view))`
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

    testing.expect_value(t, strings.contains(result.output, "support__left :: #force_inline proc(xs: []int) -> []int"), true)
    testing.expect_value(t, strings.contains(result.output, "support__right :: #force_inline proc(xs: []int) -> []int"), true)
    testing.expect_value(t, strings.contains(result.output, "#borrowed"), false)
    testing.expect_value(t, len(result.warnings), 1)
    if len(result.warnings) == 1 {
        testing.expect_value(t, result.warnings[0].message, "borrowed value escapes owner `xs`; `xs` is released when this scope exits, so the borrowed value may become invalid; return an owned copy or keep the value within the owner's lifetime")
    }
}

@(test)
compile_warns_when_only_one_branch_assigns_escaping_borrow :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")

(defn bad-view [flag?: bool] -> []int
  (let [xs (arr.range 0 10) :defer
        view: []int ([]int [])]
    (if flag?
      (set! view (arr.slice xs 0 3))
      (println 0))
    view))`

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
            kvist.Compile_Warning_Code.Ownership_Borrowed_Escape,
        )
        testing.expect_value(
            t,
            result.warnings[0].confidence,
            kvist.Compile_Warning_Confidence.Conservative,
        )
        testing.expect_value(
            t,
            result.warnings[0].message,
            "borrowed value escapes owner `xs`; `xs` is released when this scope exits, so the borrowed value may become invalid; return an owned copy or keep the value within the owner's lifetime",
        )
    }
}

@(test)
compile_warns_for_third_party_type_case_borrowed_assignment_escaping_owner :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "kvist-borrowed-escape-type-case-set-*", context.allocator)
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

(defn left [xs: []int] -> []int #force_inline
  (slice xs 0 2))

(defn right [xs: []int] -> []int #force_inline
  (slice xs 1 3))`
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
(import arr "kvist:arr")
(import support "support")

(defstruct Connected [
  id: int
])

(defstruct Disconnected [
  reason: string
])

(defunion Event [
  connected: Connected
  disconnected: Disconnected
])

(defn bad-view [event: Event] -> []int
  (let [xs (arr.range 0 10) :defer
        view: []int ([]int [])]
    (case event
      (Connected _) (set! view (support.left xs))
      (Disconnected _) (set! view (support.right xs))
      (set! view (support.left xs)))
    view))`
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

    testing.expect_value(t, strings.contains(result.output, "support__left :: #force_inline proc(xs: []int) -> []int"), true)
    testing.expect_value(t, strings.contains(result.output, "support__right :: #force_inline proc(xs: []int) -> []int"), true)
    testing.expect_value(t, strings.contains(result.output, "#borrowed"), false)
    testing.expect_value(t, len(result.warnings), 1)
    if len(result.warnings) == 1 {
        testing.expect_value(t, result.warnings[0].message, "borrowed value escapes owner `xs`; `xs` is released when this scope exits, so the borrowed value may become invalid; return an owned copy or keep the value within the owner's lifetime")
    }
}

@(test)
compile_does_not_infer_owned_slice_for_borrowed_slice_return :: proc(t: ^testing.T) {
    source := `(package main)
(import core "kvist:core")

(defn tail [xs: []int] -> []int
  (core.slice xs 1))

(defn main [xs: []int]
  (tail xs)
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

    testing.expect_value(t, strings.contains(result.output, "#owned"), false)
    testing.expect_value(t, len(result.warnings), 0)
}

@(test)
infer_owned_result_consuming_parameter_and_borrowed_result :: proc(t: ^testing.T) {
    source := `(package main)
(import arr "kvist:arr")
(import data "kvist:data")

(defn make-values [] -> [dynamic]int
  (arr.range 0 3))

(defn consume [values: [dynamic]int] -> int
  (let [result (count values)]
    (delete values)
    result))

(defn view [value: Data] -> Data
  value)

(defn demo [value: Data]
  (let [values (make-values)]
    (consume values)
    (view value)))`

    result, err, ok := kvist.compile_source_with_map(source)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer delete(result.output)
    defer kvist.source_map_slice_delete(result.source_map)
    defer kvist.compile_warning_slice_delete(result.warnings)

    testing.expect_value(t, strings.contains(result.output, "make_values :: proc() -> [dynamic]int"), true)
    testing.expect_value(t, strings.contains(result.output, "consume :: proc(values: [dynamic]int)"), true)
    testing.expect_value(t, strings.contains(result.output, "delete(values)"), true)
    testing.expect_value(t, len(result.warnings), 0)

    symbols, symbols_err, symbols_ok := kvist.symbols_source(source)
    testing.expect_value(t, symbols_ok, true)
    if symbols_ok {
        defer delete(symbols)
        testing.expect_value(t, strings.contains(symbols, "make-values\t"), true)
        testing.expect_value(t, strings.contains(symbols, "consumes=0"), true)
        testing.expect_value(t, strings.contains(symbols, "lifetime=result-borrowed"), true)
        testing.expect_value(t, strings.contains(symbols, "(owned "), false)
        testing.expect_value(t, strings.contains(symbols, "(borrowed "), false)
    } else {
        defer delete(symbols_err.message)
        testing.expect_value(t, symbols_err.message, "")
    }
}
