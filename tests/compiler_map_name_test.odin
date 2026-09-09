package tests

import "core:strings"
import "core:testing"
import kvist "../src/odin/kvist"

@(test)
map_name_preserves_mapping_and_owned_result :: proc(t: ^testing.T) {
    cases := [][2]string{
        {"", ""},
        {"unchanged_123", "unchanged_123"},
        {"has-value?", "has_value_p"},
        {"set-value!", "set_value_bang"},
        {"-?!?--!!", "__p_bang_p___bang_bang"},
    }
    for pair in cases {
        source := strings.clone(pair[0])
        actual := kvist.map_name(source)
        delete(source)
        testing.expect_value(t, actual, pair[1])
        delete(actual)
    }
    // Keep the existing rune-to-byte mapping, including malformed UTF-8;
    // changing identifier semantics is separate from this optimization.
    unicode_cases := []string{"æøå-?!", "λ🙂", "a\xff\xc0?"}
    for source in unicode_cases {
        builder := strings.builder_make()
        defer strings.builder_destroy(&builder)
        for ch in source {
            if ch == '-' {
                strings.write_byte(&builder, '_')
            } else if ch == '?' {
                strings.write_string(&builder, "_p")
            } else if ch == '!' {
                strings.write_string(&builder, "_bang")
            } else {
                strings.write_byte(&builder, byte(ch))
            }
        }
        actual := kvist.map_name(source)
        defer delete(actual)
        testing.expect_value(t, actual, strings.to_string(builder))
    }
}
