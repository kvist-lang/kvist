package tests

import "base:runtime"
import fmt "core:fmt"
import "core:os"
import "core:strings"
import "core:sync"
import "core:testing"
import kvist "../src/odin/kvist"

@(test)
imported_explicit_aggregate_destructor_covers_owned_result_fields :: proc(
    t: ^testing.T,
) {
    dir, dir_err := os.make_directory_temp(
        "",
        "kvist-package-explicit-aggregate-cleanup-*",
        context.allocator,
    )
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil do return
    defer os.remove_all(dir)
    defer delete(dir)

    support_dir, support_dir_err := os.join_path(
        {dir, "support"},
        context.allocator,
    )
    support_path, support_path_err := os.join_path(
        {support_dir, "support.kvist"},
        context.allocator,
    )
    main_path, main_path_err := os.join_path(
        {dir, "main.kvist"},
        context.allocator,
    )
    cache_dir, cache_dir_err := os.join_path(
        {dir, "cache"},
        context.allocator,
    )
    testing.expect_value(
        t,
        support_dir_err == nil && support_path_err == nil &&
        main_path_err == nil && cache_dir_err == nil,
        true,
    )
    if support_dir_err != nil || support_path_err != nil ||
       main_path_err != nil || cache_dir_err != nil {
        delete(support_dir)
        delete(support_path)
        delete(main_path)
        delete(cache_dir)
        return
    }
    defer delete(support_dir)
    defer delete(support_path)
    defer delete(main_path)
    defer delete(cache_dir)
    testing.expect_value(t, os.make_directory_all(support_dir) == nil, true)
    testing.expect_value(t, os.make_directory_all(cache_dir) == nil, true)

    support_source := `(package support)
(import fmt "core:fmt")

(defstruct State [manual: string automatic: string])

(defn make-state [] -> State
  (State
    :manual (fmt.aprintf "manual=%d" 42)
    :automatic (fmt.aprintf "automatic=%d" 42)))

(defn delete-state! [state: ^State]
  (delete state^.manual))`
    main_source := `(package main)
(import support "support")

(defn use [] -> int
  (let [state (support.make-state)]
    (defer (support.delete-state! (addr state)))
    (count state.manual)))`
    testing.expect_value(
        t,
        os.write_entire_file_from_string(support_path, support_source) == nil,
        true,
    )
    testing.expect_value(
        t,
        os.write_entire_file_from_string(main_path, main_source) == nil,
        true,
    )

    result, err, ok := kvist.compile_path_with_package_artifacts(
        main_path,
        cache_dir = cache_dir,
    )
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    testing.expect_value(t, len(result.root.warnings), 0)
    testing.expect_value(
        t,
        strings.contains(result.root.output, "defer delete(state.manual)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(result.root.output, "defer delete(state.automatic)"),
        true,
    )
    kvist.package_emit_result_delete(&result)

    cached, cached_err, cached_ok :=
        kvist.compile_path_with_package_artifacts(
            main_path,
            cache_dir = cache_dir,
        )
    testing.expect_value(t, cached_ok, true)
    if !cached_ok {
        testing.expect_value(t, cached_err.message, "")
        return
    }
    defer kvist.package_emit_result_delete(&cached)
    testing.expect_value(t, cached.packages_reused > 0, true)
    testing.expect_value(
        t,
        strings.contains(cached.root.output, "defer delete(state.manual)"),
        false,
    )
    testing.expect_value(
        t,
        strings.contains(cached.root.output, "defer delete(state.automatic)"),
        true,
    )
}

@(test)
compile_path_emits_imported_package_artifacts :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "kvist-package-artifacts-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer os.remove_all(dir)
    defer delete(dir)

    support_dir, support_dir_err := os.join_path({dir, "support"}, context.allocator)
    main_path, main_err := os.join_path({dir, "main.kvist"}, context.allocator)
    support_path, support_err := os.join_path({support_dir, "support.kvist"}, context.allocator)
    testing.expect_value(t, support_dir_err == nil && main_err == nil && support_err == nil, true)
    if support_dir_err != nil || main_err != nil || support_err != nil {
        return
    }
    defer delete(support_dir)
    defer delete(main_path)
    defer delete(support_path)
    testing.expect_value(t, os.make_directory_all(support_dir) == nil, true)
    testing.expect_value(t, os.write_entire_file_from_string(main_path, `(package main)
(import support "support")
(defn main [] (println support.answer))`) == nil, true)
    testing.expect_value(t, os.write_entire_file_from_string(support_path, `(package support)
(def answer 42)`) == nil, true)

    result, err, ok := kvist.compile_path_with_package_artifacts(main_path)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer kvist.package_emit_result_delete(&result)
    testing.expect_value(t, len(result.artifacts) > 0, true)
    testing.expect_value(t, strings.contains(result.root.output, "__KVIST_PACKAGE_"), true)
    testing.expect_value(t, strings.contains(result.root.output, ".support__answer"), true)
}
@(test)
package_artifacts_keep_parallel_helpers_with_their_calling_package :: proc(t: ^testing.T) {
    repo_root := compiler_test_repo_root()
    example_path, path_err := os.join_path(
        {repo_root, "examples", "packages", "parallel.kvist"},
        context.allocator,
    )
    testing.expect_value(t, path_err == nil, true)
    if path_err != nil {
        return
    }
    defer delete(example_path)

    result, err, ok := kvist.compile_path_with_package_artifacts(example_path)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    defer kvist.package_emit_result_delete(&result)

    testing.expect_value(
        t,
        strings.contains(result.root.output, "thread_start_square_int_int :: proc"),
        true,
    )
    testing.expect_value(
        t,
        strings.contains(result.root.output, ".parallel_Task(int)"),
        true,
    )

    found_parallel_package := false
    for artifact in result.artifacts {
        if artifact.id == "kvp_shared" {
            testing.expect_value(t, strings.contains(artifact.output, "thread_start_"), false)
            testing.expect_value(t, strings.contains(artifact.output, "thread_detach_"), false)
            continue
        }
        if strings.contains(artifact.output, "parallel_Task :: struct") {
            found_parallel_package = true
            testing.expect_value(
                t,
                strings.contains(artifact.output, "thread_start_p__map_worker"),
                true,
            )
            testing.expect_value(
                t,
                strings.contains(artifact.output, "thread_start_p__for_worker"),
                true,
            )
        }
    }
    testing.expect_value(t, found_parallel_package, true)
}

@(test)
package_artifacts_preserve_explicitly_qualified_foreign_types :: proc(
	t: ^testing.T,
) {
	origins := make(map[string]kvist.Package_Symbol_Origin)
	defer delete(origins)
	origins["Data"] = {
		package_id = "kvp_shared",
		symbol = "Data",
	}
	qualified, dependencies := kvist.qualify_generated_package_output(
		"wrapped: native.Data\nplain: Data\n",
		origins,
	)
	defer delete(qualified)
	defer kvist.delete_string_slice(&dependencies)
	testing.expect_value(
		t,
		strings.contains(qualified, "wrapped: native.Data"),
		true,
	)
	testing.expect_value(
		t,
		strings.contains(qualified, "native.kvp_shared.Data"),
		false,
	)
	testing.expect_value(
		t,
		strings.contains(qualified, "plain: kvp_shared.Data"),
		true,
	)
	testing.expect_value(t, len(dependencies), 1)
	testing.expect_value(t, dependencies[0], "kvp_shared")
}

@(test)
package_artifact_source_hash_includes_resolved_declaration_identity :: proc(t: ^testing.T) {
    path, ok_path := repo_temp_test_path(".tmp-package-artifact-hash.kvist")
    testing.expect_value(t, ok_path, true)
    if !ok_path do return
    defer {
        _ = os.remove(path)
        delete(path)
    }
    testing.expect_value(
        t,
        os.write_entire_file_from_string(path, "(package helper)\n(defn value [] -> int 1)\n") == nil,
        true,
    )
    first := kvist.IR_Package_Group{decls = make([dynamic]kvist.IR_Decl)}
    second := kvist.IR_Package_Group{decls = make([dynamic]kvist.IR_Decl)}
    a_decl := kvist.IR_Decl{
        kind = .Proc,
        source_path = path,
        proc_decl = kvist.Proc_Decl{name = "a__helper__value"},
    }
    append(&first.decls, a_decl)
    append(&second.decls, a_decl)
    append(&second.decls, kvist.IR_Decl{
        kind = .Proc,
        source_path = path,
        proc_decl = kvist.Proc_Decl{name = "b__helper__value"},
    })
    defer {
        delete(first.decls)
        delete(second.decls)
    }
    first_hash, first_ok := kvist.package_group_source_hash(first)
    second_hash, second_ok := kvist.package_group_source_hash(second)
    testing.expect_value(t, first_ok, true)
    testing.expect_value(t, second_ok, true)
    testing.expect_value(t, first_hash != second_hash, true)
}

@(test)
package_artifact_cache_tracks_aggregate_result_ownership_contracts :: proc(
    t: ^testing.T,
) {
    dir, dir_err := os.make_directory_temp(
        "",
        "kvist-package-owned-result-*",
        context.allocator,
    )
    testing.expect_value(t, dir_err == nil, true)
    if dir_err != nil {
        return
    }
    defer os.remove_all(dir)
    defer delete(dir)

    support_dir, support_dir_err := os.join_path(
        {dir, "support"},
        context.allocator,
    )
    support_path, support_path_err := os.join_path(
        {support_dir, "support.kvist"},
        context.allocator,
    )
    main_path, main_path_err := os.join_path(
        {dir, "main.kvist"},
        context.allocator,
    )
    cache_dir, cache_dir_err := os.join_path(
        {dir, "cache"},
        context.allocator,
    )
    testing.expect_value(
        t,
        support_dir_err == nil && support_path_err == nil &&
        main_path_err == nil && cache_dir_err == nil,
        true,
    )
    if support_dir_err != nil || support_path_err != nil ||
       main_path_err != nil || cache_dir_err != nil {
        delete(support_dir)
        delete(support_path)
        delete(main_path)
        delete(cache_dir)
        return
    }
    defer delete(support_dir)
    defer delete(support_path)
    defer delete(main_path)
    defer delete(cache_dir)
    testing.expect_value(t, os.make_directory_all(support_dir) == nil, true)
    testing.expect_value(t, os.make_directory_all(cache_dir) == nil, true)

    main_source := `(package main)
(import support "support")

(defn use [path: string, borrowed: []byte] -> int
  (let [box (support.make-owned-bytes path borrowed)]
    (count box.data)))`
    owned_support_source := `(package support)
(import os "core:os")

(defstruct Owned-Bytes [data: []byte])

(defn make-owned-bytes [path: string, borrowed: []byte] -> Owned-Bytes
  (let [[data err] (os.read_entire_file path context.allocator)
        boxed (Owned-Bytes :data data)]
    (discard borrowed)
    (discard err)
    boxed))`
    borrowed_support_source := `(package support)
(import os "core:os")

(defstruct Owned-Bytes [data: []byte])

(defn make-owned-bytes [path: string, borrowed: []byte] -> Owned-Bytes
  (discard (os.exists path))
  (Owned-Bytes :data borrowed))`
    testing.expect_value(
        t,
        os.write_entire_file_from_string(main_path, main_source) == nil,
        true,
    )
    testing.expect_value(
        t,
        os.write_entire_file_from_string(
            support_path,
            owned_support_source,
        ) == nil,
        true,
    )

    first, first_err, first_ok := kvist.compile_path_with_package_artifacts(
        main_path,
        cache_dir = cache_dir,
    )
    testing.expect_value(t, first_ok, true)
    if !first_ok {
        testing.expect_value(t, first_err.message, "")
        return
    }
    testing.expect_value(
        t,
        strings.contains(first.root.output, "defer delete(box.data)"),
        true,
    )
    testing.expect_value(t, len(first.root.warnings), 0)
    kvist.package_emit_result_delete(&first)

    lifetimes, lifetimes_err, lifetimes_ok := kvist.lifetimes_path(
        support_path,
    )
    testing.expect_value(t, lifetimes_ok, true)
    if lifetimes_ok {
        testing.expect_value(
            t,
            strings.contains(
                lifetimes,
                "result field data: owned; ownership transfers to the caller and automatic scoped cleanup is available",
            ),
            true,
        )
        delete(lifetimes)
    } else {
        testing.expect_value(t, lifetimes_err.message, "")
    }

    testing.expect_value(
        t,
        os.write_entire_file_from_string(
            support_path,
            borrowed_support_source,
        ) == nil,
        true,
    )
    second, second_err, second_ok := kvist.compile_path_with_package_artifacts(
        main_path,
        cache_dir = cache_dir,
    )
    testing.expect_value(t, second_ok, true)
    if !second_ok {
        testing.expect_value(t, second_err.message, "")
        return
    }
    testing.expect_value(
        t,
        strings.contains(second.root.output, "defer delete(box.data)"),
        false,
    )
    testing.expect_value(t, len(second.root.warnings), 0)
    testing.expect_value(t, second.packages_reused, 0)
    kvist.package_emit_result_delete(&second)

    third, third_err, third_ok := kvist.compile_path_with_package_artifacts(
        main_path,
        cache_dir = cache_dir,
    )
    testing.expect_value(t, third_ok, true)
    if !third_ok {
        testing.expect_value(t, third_err.message, "")
        return
    }
    defer kvist.package_emit_result_delete(&third)
    testing.expect_value(
        t,
        strings.contains(third.root.output, "defer delete(box.data)"),
        false,
    )
    testing.expect_value(t, third.packages_reused >= 2, true)
}
