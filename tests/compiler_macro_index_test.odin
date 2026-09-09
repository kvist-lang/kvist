package tests

import "core:testing"
import "core:strings"
import "core:fmt"
import kvist "../src/odin/kvist"

@(test)
macro_index_preserves_shadowing_and_generated_definitions :: proc(t: ^testing.T) {
    sources := []string{
        `(package main)
(defmacro answer [] 1)
(defmacro answer [] 23)
(def result (answer))`,
        `(package main)
(defmacro answer [] 1)
(defmacro install [] '(defmacro answer [] 23))
(install)
(def result (answer))`,
        `(package main)
(defmacro install [] '(defmacro answer [] 23))
(install)
(def result (answer))`,
    }
    for source in sources {
        output, err, ok := kvist.compile_source(source)
        defer delete(output)
        defer delete(err.message)
        testing.expect_value(t, ok, true)
        if !ok {
            testing.expect_value(t, err.message, "")
            continue
        }
        testing.expect_value(t, strings.contains(output, "result :: 23"), true)
        testing.expect_value(t, kvist.active_macro_lookup_index == nil, true)
    }
}

@(test)
macro_index_restores_outer_scope_after_success_and_error :: proc(t: ^testing.T) {
    outer_macros := []kvist.User_Macro{{name = "outer"}}
    outer := kvist.Macro_Lookup_Index{
        macros = outer_macros,
        positions = make(map[string]int),
    }
    defer delete(outer.positions)
    outer.positions["outer"] = 0
    previous := kvist.active_macro_lookup_index
    kvist.active_macro_lookup_index = &outer
    defer kvist.active_macro_lookup_index = previous

    sources := []string{
        `(package main) (defmacro value [] 42) (def result (value))`,
        `(package main) (defmacro value [x] x) (def result (value))`,
    }
    for source, index in sources {
        output, err, ok := kvist.compile_source(source)
        defer delete(output)
        defer delete(err.message)
        testing.expect_value(t, ok, index == 0)
        testing.expect_value(t, kvist.active_macro_lookup_index == &outer, true)
        _, found := kvist.find_user_macro(outer_macros, "outer")
        testing.expect_value(t, found, true)
    }
    // A different environment must not accidentally use the active index,
    // even if its length matches. Smaller slices must also use their own scope.
    other := []kvist.User_Macro{{name = "other"}}
    _, found_other := kvist.find_user_macro(other, "other")
    _, found_outer := kvist.find_user_macro(other, "outer")
    _, found_empty := kvist.find_user_macro(outer_macros[:0], "outer")
    testing.expect_value(t, found_other, true)
    testing.expect_value(t, found_outer, false)
    testing.expect_value(t, found_empty, false)
}

@(test)
macro_index_tracks_generated_macro_buffer_growth :: proc(t: ^testing.T) {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    strings.write_string(&builder, `(package main)
(defmacro install [name value]
  (quasiquote (defmacro (unquote name) [] (unquote value))))
`)
    for i in 0..<256 {
        fmt.sbprintf(&builder, "(install generated-%d %d)\n", i, i)
    }
    strings.write_string(&builder, "(def result (generated-255))\n")
    output, err, ok := kvist.compile_source(strings.to_string(builder))
    defer delete(output)
    defer delete(err.message)
    testing.expect_value(t, ok, true)
    if !ok {
        testing.expect_value(t, err.message, "")
        return
    }
    testing.expect_value(t, strings.contains(output, "result :: 255"), true)
    testing.expect_value(t, kvist.active_macro_lookup_index == nil, true)
}
