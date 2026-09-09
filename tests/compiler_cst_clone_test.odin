package tests

import "core:strings"
import "core:testing"
import kvist "../src/odin/kvist"

@(test)
cst_clone_preserves_owned_tree_with_exact_child_capacity :: proc(t: ^testing.T) {
    sizes := []int{0, 1, 2, 7, 8, 9, 64, 257}
    for size in sizes {
        original := kvist.CST_Form{
            kind = .Vector,
            text = strings.clone("root"),
            source_text = strings.clone("[root]"),
            span = {start = 4, end = 10, source = .Eval},
        }
        for i in 0..<size {
            child := kvist.CST_Form{
                kind = .List,
                source_text = strings.clone("(value)"),
            }
            append(&child.items, kvist.CST_Form{
                kind = .Symbol,
                text = strings.clone("value"),
                source_text = strings.clone("value"),
                span = {start = i, end = i+1},
            })
            append(&original.items, child)
        }
        cloned := kvist.clone_cst_form(original)
        kvist.delete_cst_form(&original)
        defer kvist.delete_cst_form(&cloned)
        testing.expect_value(t, cloned.kind, kvist.CST_Form_Kind.Vector)
        testing.expect_value(t, cloned.text, "root")
        testing.expect_value(t, cloned.source_text, "[root]")
        testing.expect_value(t, cloned.span.start, 4)
        testing.expect_value(t, cloned.span.end, 10)
        testing.expect_value(t, cloned.span.source, kvist.Source_Kind.Eval)
        testing.expect_value(t, len(cloned.items), size)
        testing.expect_value(t, cap(cloned.items), size)
        for child, i in cloned.items {
            testing.expect_value(t, child.kind, kvist.CST_Form_Kind.List)
            testing.expect_value(t, child.source_text, "(value)")
            testing.expect_value(t, len(child.items), 1)
            testing.expect_value(t, cap(child.items), 1)
            testing.expect_value(t, child.items[0].text, "value")
            testing.expect_value(t, child.items[0].source_text, "value")
            testing.expect_value(t, child.items[0].span.start, i)
            testing.expect_value(t, child.items[0].items == nil, true)
        }
        // Cloned arrays remain ordinary growable arrays, not fixed slices.
        append(&cloned.items, kvist.CST_Form{kind = .Nil})
        testing.expect_value(t, len(cloned.items), size+1)
    }
}

@(test)
cst_clone_slice_preserves_independence_and_empty_result :: proc(t: ^testing.T) {
    empty := kvist.clone_cst_form_slice(nil)
    testing.expect_value(t, empty == nil, true)
    original := []kvist.CST_Form{{kind = .Symbol, text = "before"}, {kind = .Nil}}
    cloned := kvist.clone_cst_form_slice(original)
    defer kvist.delete_cst_form_slice(&cloned)
    original[0].text = "after"
    testing.expect_value(t, cloned[0].text, "before")
    testing.expect_value(t, cloned[1].kind, kvist.CST_Form_Kind.Nil)
    testing.expect_value(t, cap(cloned), len(original))
}
