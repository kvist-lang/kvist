package tests

import "core:fmt"
import "core:testing"
import kvist "../src/odin/kvist"

@(test)
literal_name_index_preserves_existing_names_and_counters :: proc(t: ^testing.T) {
    features := kvist.Emitter_Features{}
    defer delete(features.data_literals)
    append(&features.data_literals,
        kvist.Data_Literal{name = "kvist_data_literal_1"},
        kvist.Data_Literal{name = "kvist_data_literal_3"},
        kvist.Data_Literal{name = "kvist_data_backing_1"},
        kvist.Data_Literal{name = "kvist_data_literal_pkg_1"},
    )
    e := kvist.Emitter{features = &features}
    name := kvist.next_data_literal_name(&e)
    testing.expect_value(t, name, "kvist_data_literal_2")
    backing := kvist.next_data_literal_name(&e, true)
    testing.expect_value(t, backing, "kvist_data_backing_2")
    next := kvist.next_data_literal_name(&e)
    testing.expect_value(t, next, "kvist_data_literal_4")

    prefixed := kvist.Emitter{features = &features, data_literal_prefix = "pkg"}
    package_name := kvist.next_data_literal_name(&prefixed)
    testing.expect_value(t, package_name, "kvist_data_literal_pkg_2")
    testing.expect_value(t, e.temp_counter, 4)
    testing.expect_value(t, e.data_backing_counter, 2)
}

@(test)
literal_name_index_tracks_appends_and_shared_emitters :: proc(t: ^testing.T) {
    features := kvist.Emitter_Features{}
    defer delete(features.data_literals)
    e := kvist.Emitter{features = &features}
    first := kvist.next_data_literal_name(&e)
    append(&features.data_literals, kvist.Data_Literal{name = first})
    // Reallocation and names installed by another emitter must remain visible.
    for i in 2..<258 {
        name := fmt.aprintf("kvist_data_literal_%d", i)
        append(&features.data_literals, kvist.Data_Literal{name = name})
    }
    defer for literal in features.data_literals[1:257] {
        delete(literal.name)
    }
    second := kvist.Emitter{features = &features}
    second_name := kvist.next_data_literal_name(&second)
    testing.expect_value(t, second_name, "kvist_data_literal_258")
    append(&features.data_literals, kvist.Data_Literal{name = second_name})
    next := kvist.next_data_literal_name(&e)
    testing.expect_value(t, next, "kvist_data_literal_259")
    testing.expect_value(t, e.indexed_data_literal_count, len(features.data_literals))
}
