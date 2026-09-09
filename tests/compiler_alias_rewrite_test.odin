package tests

import "core:testing"
import kvist "../src/odin/kvist"

@(test)
alias_rewrite_preserves_separator_boundaries_and_prefixes :: proc(t: ^testing.T) {
    aliases := []kvist.Alias_Prefix{{alias = "pkg", prefix = "dest"}}
    cases := [][2]string{
        {"pkg.value", "dest__value"},
        {"'pkg.value", "'dest__value"},
        {"^&pkg.value", "^&dest__value"},
        {"[]pkg.value", "[]dest__value"},
        {"pkg", "pkg"},
        {"pkg.", "pkg."},
        {"pkg/", "pkg/"},
        {"pk", "pk"},
        {"", ""},
        {"pkgx.value", "pkgx.value"},
        {"pkgx/value", "pkgx/value"},
    }
    for pair in cases {
        actual, _, ok := kvist.rewrite_symbol_text(pair[0], nil, aliases, "")
        testing.expect_value(t, ok, true)
        testing.expect_value(t, actual, pair[1])
    }
    _, err, ok := kvist.rewrite_symbol_text("pkg/value", nil, aliases, "")
    testing.expect_value(t, ok, false)
    testing.expect_value(t, err.message, "use `pkg.value` for package access")
    aliases[0].alias = ""
    actual, _, empty_ok := kvist.rewrite_symbol_text(".value", nil, aliases, "")
    testing.expect_value(t, empty_ok, true)
    testing.expect_value(t, actual, "dest__value")
}

@(test)
alias_rewrite_preserves_visibility_raw_exports_and_alias_order :: proc(t: ^testing.T) {
    exports, raw_exports: [dynamic]string
    append(&exports, "public")
    append(&raw_exports, "raw_member")
    defer delete(exports)
    defer delete(raw_exports)
    aliases := []kvist.Alias_Prefix{
        {alias = "p", prefix = "short"},
        {alias = "pkg", prefix = "dest", exports = exports, raw_exports = raw_exports, raw_prefix = "native"},
        {alias = "pkg", prefix = "later"},
    }
    actual, _, ok := kvist.rewrite_symbol_text("pkg.public", nil, aliases, "")
    testing.expect_value(t, ok, true)
    testing.expect_value(t, actual, "dest__public")
    raw, _, raw_ok := kvist.rewrite_symbol_text("pkg.raw-member", nil, aliases, "")
    testing.expect_value(t, raw_ok, true)
    testing.expect_value(t, raw, "native.raw_member")
    _, err, private_ok := kvist.rewrite_symbol_text("pkg.private", nil, aliases, "")
    testing.expect_value(t, private_ok, false)
    testing.expect_value(t, err.message, "source package member is private or undefined: pkg.private")
    aliases[1].preserve_qualified_calls = true
    preserved, _, preserved_ok := kvist.rewrite_symbol_text("pkg.private", nil, aliases, "")
    testing.expect_value(t, preserved_ok, true)
    testing.expect_value(t, preserved, "pkg.private")
}
