package tests

import "core:os"
import "core:strings"
import "core:testing"
import kvist "../src/odin/kvist"

core_exports_fixture :: proc(t: ^testing.T, source: string) -> (dir, path: string) {
    directory, dir_err := os.make_directory_temp("", "kvist-core-exports-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    file_path, path_err := os.join_path({directory, "core.kvist"}, context.allocator)
    testing.expect_value(t, path_err == nil, true)
    write_err := os.write_entire_file_from_string(file_path, source)
    testing.expect_value(t, write_err == nil, true)
    return directory, file_path
}

@(test)
core_exports_cache_owns_names_and_refreshes_after_scope :: proc(t: ^testing.T) {
    dir, path := core_exports_fixture(t, "(package core) (def visible 1) (defn- hidden [] 2)")
    defer delete(dir)
    defer delete(path)
    defer os.remove_all(dir)
    cache := kvist.Core_Exports_Cache{}
    defer kvist.core_exports_cache_delete(&cache)

    first, _, first_ok := kvist.read_core_exports(dir, &cache)
    defer kvist.delete_string_slice(&first)
    testing.expect_value(t, first_ok, true)
    testing.expect_value(t, len(first), 1)
    if len(first) != 1 { return }
    testing.expect_value(t, first[0], "visible")
    delete(first[0])
    first[0] = strings.clone("caller-mutation")

    write_err := os.write_entire_file_from_string(path, "(package core) (def updated 2)")
    testing.expect_value(t, write_err == nil, true)
    cached, _, cached_ok := kvist.read_core_exports(dir, &cache)
    defer kvist.delete_string_slice(&cached)
    testing.expect_value(t, cached_ok, true)
    testing.expect_value(t, len(cached), 1)
    if len(cached) != 1 { return }
    testing.expect_value(t, cached[0], "visible")
    testing.expect_value(t, len(cache.entries), 1)

    kvist.core_exports_cache_delete(&cache)
    testing.expect_value(t, cached[0], "visible")
    testing.expect_value(t, len(cache.entries), 0)
    refreshed, _, refreshed_ok := kvist.read_core_exports(dir, &cache)
    defer kvist.delete_string_slice(&refreshed)
    testing.expect_value(t, refreshed_ok, true)
    testing.expect_value(t, len(refreshed), 1)
    if len(refreshed) == 1 {
        testing.expect_value(t, refreshed[0], "updated")
    }
}

@(test)
core_exports_cache_separates_paths_and_caches_empty_exports :: proc(t: ^testing.T) {
    first_dir, first_path := core_exports_fixture(t, "(package core)")
    defer delete(first_dir)
    defer delete(first_path)
    defer os.remove_all(first_dir)
    second_dir, second_path := core_exports_fixture(t, "(package core) (def other 1)")
    defer delete(second_dir)
    defer delete(second_path)
    defer os.remove_all(second_dir)
    cache := kvist.Core_Exports_Cache{}
    defer kvist.core_exports_cache_delete(&cache)

    empty, _, empty_ok := kvist.read_core_exports(first_dir, &cache)
    defer kvist.delete_string_slice(&empty)
    testing.expect_value(t, empty_ok, true)
    testing.expect_value(t, len(empty), 0)
    other, _, other_ok := kvist.read_core_exports(second_dir, &cache)
    defer kvist.delete_string_slice(&other)
    testing.expect_value(t, other_ok, true)
    testing.expect_value(t, len(other), 1)
    if len(other) == 1 { testing.expect_value(t, other[0], "other") }
    testing.expect_value(t, len(cache.entries), 2)
    testing.expect_value(t, os.write_entire_file_from_string(first_path, "(package core) (def new 1)") == nil, true)
    still_empty, _, still_ok := kvist.read_core_exports(first_dir, &cache)
    defer kvist.delete_string_slice(&still_empty)
    testing.expect_value(t, still_ok, true)
    testing.expect_value(t, len(still_empty), 0)
    uncached, _, uncached_ok := kvist.read_core_exports(first_dir)
    defer kvist.delete_string_slice(&uncached)
    testing.expect_value(t, uncached_ok, true)
    testing.expect_value(t, len(uncached), 1)
}

@(test)
core_exports_cache_does_not_cache_failed_reads :: proc(t: ^testing.T) {
    dir, dir_err := os.make_directory_temp("", "kvist-core-exports-retry-*", context.allocator)
    testing.expect_value(t, dir_err == nil, true)
    defer delete(dir)
    defer os.remove_all(dir)
    cache := kvist.Core_Exports_Cache{}
    defer kvist.core_exports_cache_delete(&cache)
    failed, _, failed_ok := kvist.read_core_exports(dir, &cache)
    defer kvist.delete_string_slice(&failed)
    testing.expect_value(t, failed_ok, false)
    testing.expect_value(t, len(cache.entries), 0)
    path, path_err := os.join_path({dir, "core.kvist"}, context.allocator)
    testing.expect_value(t, path_err == nil, true)
    defer delete(path)
    testing.expect_value(t, os.write_entire_file_from_string(path, "(package core) (def retry 1)") == nil, true)
    retried, _, retried_ok := kvist.read_core_exports(dir, &cache)
    defer kvist.delete_string_slice(&retried)
    testing.expect_value(t, retried_ok, true)
    testing.expect_value(t, len(cache.entries), 1)
    testing.expect_value(t, len(retried), 1)
    if len(retried) == 1 { testing.expect_value(t, retried[0], "retry") }
}
