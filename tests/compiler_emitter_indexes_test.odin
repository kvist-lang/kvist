package tests

import "core:fmt"
import "core:strings"
import "core:testing"
import kvist "../src/odin/kvist"

@(test)
proc_literal_emitters_share_global_indexes_but_not_local_bindings :: proc(t: ^testing.T) {
    decls := []kvist.IR_Decl{
        {kind = .Proc, proc_decl = {name = "answer"}},
        {kind = .Proc, proc_decl = {name = "answer"}},
        {kind = .Const, const_decl = {name = "constant"}},
    }
    parent := kvist.Emitter{decls = decls, temp_counter = 7}
    kvist.bind_local_type(&parent, "value", "int")
    defer delete(parent.local_types)
    child := kvist.proc_literal_emitter(&parent, {})
    defer strings.builder_destroy(&child.builder)
    grandchild := kvist.proc_literal_emitter(&child, {})
    defer strings.builder_destroy(&grandchild.builder)
    testing.expect_value(t, parent.indexes != nil, true)
    testing.expect_value(t, child.indexes == parent.indexes, true)
    testing.expect_value(t, grandchild.indexes == parent.indexes, true)
    testing.expect_value(t, child.proc_indices["answer"], 0)
    testing.expect_value(t, child.const_indices["constant"], 2)
    testing.expect_value(t, child.decl_indices["answer"], 0)

    kvist.bind_local_type(&child, "value", "bool")
    defer delete(child.local_types)
    parent_type, _ := kvist.lookup_local_type(&parent, "value")
    child_type, _ := kvist.lookup_local_type(&child, "value")
    testing.expect_value(t, parent_type, "int")
    testing.expect_value(t, child_type, "bool")
    child.temp_counter += 1
    testing.expect_value(t, parent.temp_counter, 7)
    testing.expect_value(t, child.temp_counter, 8)
    kvist.ensure_emitter_indexes(&child)
    testing.expect_value(t, child.indexes == parent.indexes, true)

    independent := kvist.Emitter{decls = decls}
    kvist.ensure_emitter_indexes(&independent)
    testing.expect_value(t, independent.indexes != parent.indexes, true)
}

@(test)
shared_emitter_index_caches_survive_map_growth :: proc(t: ^testing.T) {
    parent := kvist.Emitter{}
    child := kvist.proc_literal_emitter(&parent, {})
    defer strings.builder_destroy(&child.builder)
    grandchild := kvist.proc_literal_emitter(&child, {})
    defer strings.builder_destroy(&grandchild.builder)
    // These maps grow lazily. Sharing only copied map headers would leave the
    // parent with stale length/capacity or a freed backing allocation.
    for i in 0..<512 {
        name := fmt.tprintf("missing_%d", i)
        testing.expect_value(t, kvist.kvist_package_imported(&grandchild, name), false)
        _ = kvist.emitter_import_cache_key(&child, name, "core:fmt", "fmt", name)
    }
    testing.expect_value(t, len(parent.kvist_package_presence), 512)
    testing.expect_value(t, len(parent.odin_import_cache_keys), 512)
    for i in 0..<512 {
        name := fmt.tprintf("missing_%d", i)
        present, found := parent.kvist_package_presence[name]
        testing.expect_value(t, found, true)
        testing.expect_value(t, present, false)
        cached, cache_found := grandchild.odin_import_cache_keys[name]
        testing.expect_value(t, cache_found, true)
        testing.expect_value(t, cached, kvist.emitter_import_cache_key(&parent, name, "core:fmt", "fmt", name))
    }
    separate := kvist.Emitter{}
    kvist.ensure_emitter_indexes(&separate)
    testing.expect_value(t, len(separate.kvist_package_presence), 0)
    testing.expect_value(t, len(separate.odin_import_cache_keys), 0)
}

@(test)
shared_emitter_indexes_preserve_local_type_shadowing :: proc(t: ^testing.T) {
    parent := kvist.Emitter{}
    append(&parent.structs, kvist.Struct_Decl{name = "Record"})
    append(&parent.local_structs, kvist.Struct_Decl{name = "Record"})
    append(&parent.unions, kvist.Union_Decl{name = "Choice"})
    append(&parent.local_unions, kvist.Union_Decl{name = "Choice"})
    defer delete(parent.structs)
    defer delete(parent.local_structs)
    defer delete(parent.unions)
    defer delete(parent.local_unions)
    child := kvist.proc_literal_emitter(&parent, {})
    defer strings.builder_destroy(&child.builder)
    local_struct, struct_ok := kvist.find_struct_decl(&child, "Record")
    local_union, union_ok := kvist.find_union_decl(&child, "Choice")
    testing.expect_value(t, struct_ok && union_ok, true)
    testing.expect_value(t, local_struct == &parent.local_structs[0], true)
    testing.expect_value(t, local_union == &parent.local_unions[0], true)
    child.local_structs = nil
    child.local_unions = nil
    global_struct, _ := kvist.find_struct_decl(&child, "Record")
    global_union, _ := kvist.find_union_decl(&child, "Choice")
    testing.expect_value(t, global_struct == &parent.structs[0], true)
    testing.expect_value(t, global_union == &parent.unions[0], true)
    testing.expect_value(t, len(parent.local_structs), 1)
    testing.expect_value(t, len(parent.local_unions), 1)
}
