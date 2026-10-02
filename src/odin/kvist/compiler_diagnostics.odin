package kvist

import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"
import "core:time"
import "base:runtime"

source_position :: proc(source: string, pos: int) -> (line, column, line_start, line_end: int) {
    clamped_pos := pos
    if clamped_pos < 0 {
        clamped_pos = 0
    }
    if clamped_pos > len(source) {
        clamped_pos = len(source)
    }

    line = 1
    column = 1
    line_start = 0
    i := 0
    for i < clamped_pos {
        if source[i] == '\n' {
            line += 1
            column = 1
            line_start = i + 1
        } else {
            column += 1
        }
        i += 1
    }

    line_end = clamped_pos
    for line_end < len(source) && source[line_end] != '\n' {
        line_end += 1
    }
    return
}

format_compile_error :: proc(path, source: string, err: Compile_Error) -> string {
    label := path
    if err.source_path != "" {
        label = err.source_path
    }
    if label == "" {
        label = "<source>"
    }
    source_text := source
    owned_source: []byte
    defer if owned_source != nil {
        delete(owned_source)
    }
    if err.source_file != "" {
        source_text = err.source_file
    } else if err.source_path != "" && err.source_path != path {
        imported_source, read_err := os.read_entire_file_from_path(err.source_path, context.allocator)
        if read_err == nil {
            owned_source = imported_source
            source_text = string(imported_source)
        }
    }
    message := err.message
    if message == "" {
        message = "compile error"
    }

    line, column, line_start, line_end := source_position(source_text, err.span.start)
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    fmt.sbprintf(&builder, "%s:%d:%d: %s\n", label, line, column, message)
    if line_start <= line_end && line_end <= len(source_text) {
        fmt.sbprintf(&builder, "  %s\n  ", source_text[line_start:line_end])
        i := 1
        for i < column {
            strings.write_byte(&builder, ' ')
            i += 1
        }
        strings.write_string(&builder, "^\n")
    }
    return strings.clone(strings.to_string(builder))
}

format_eval_compile_error :: proc(path, source, eval_source: string, err: Compile_Error) -> string {
    if err.span.source == .Eval {
        label := "<eval>"
        if path != "" {
            label = fmt.tprintf("%s:<eval>", path)
        }
        return format_compile_error(label, eval_source, err)
    }
    return format_compile_error(path, source, err)
}

format_compile_warning :: proc(path, source: string, warning: Compile_Warning) -> string {
    label := path
    if warning.source_path != "" {
        label = warning.source_path
    }
    if label == "" {
        label = "<source>"
    }
    source_text := source
    owned_source: []byte
    defer if owned_source != nil {
        delete(owned_source)
    }
    if warning.source_path != "" &&
       (warning.source_path != path || source_text == "") {
        imported_source, read_err := os.read_entire_file_from_path(
            warning.source_path,
            context.allocator,
        )
        if read_err == nil {
            owned_source = imported_source
            source_text = string(imported_source)
        }
    }
    message := warning.message
    if message == "" {
        message = "warning"
    }
    inferred_line, inferred_column, line_start, line_end :=
        source_position(source_text, warning.span.start)
    line := warning.line
    column := warning.column
    if line <= 0 || column <= 0 {
        line, column = inferred_line, inferred_column
    }
    code := compile_warning_code_text(warning.code)
    name := compile_warning_name(warning.code)
    confidence := ""
    if warning.confidence == .Conservative {
        confidence = ", conservative"
    }
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    fmt.sbprintf(
        &builder,
        "%s:%d:%d: warning[%s/%s%s]: %s\n",
        label,
        line,
        column,
        code,
        name,
        confidence,
        message,
    )
    if source_text != "" && line_start <= line_end && line_end <= len(source_text) {
        fmt.sbprintf(&builder, "  %s\n  ", source_text[line_start:line_end])
        i := 1
        for i < column {
            strings.write_byte(&builder, ' ')
            i += 1
        }
        strings.write_string(&builder, "^\n")
    }
    return strings.clone(strings.to_string(builder))
}

compile_warning_name :: proc(code: Compile_Warning_Code) -> string {
    switch code {
    case .General:
        return "general-warning"
    case .Ownership_Discarded_Result:
        return "discarded-owned-result"
    case .Ownership_Unreleased_Local:
        return "unreleased-owned-local"
    case .Ownership_Use_After_Transfer:
        return "use-after-ownership-transfer"
    case .Ownership_Overwrite:
        return "overwrite-before-cleanup"
    case .Ownership_Borrowed_Escape:
        return "invalid-borrow-lifetime"
    case .Ownership_Delete_Borrowed:
        return "delete-of-borrowed-value"
    case .Ownership_Defer_In_Loop:
        return "defer-inside-loop"
    case .Ownership_Automatic_Cleanup_Skipped:
        return "automatic-cleanup-not-proven"
    case .Repl_Unretained_Lifecycle:
        return "unretained-repl-result"
    }
    return "general-warning"
}

compile_warning_description :: proc(code: Compile_Warning_Code) -> string {
    switch code {
    case .General:
        return "A compiler warning without a more specific diagnostic category."
    case .Ownership_Discarded_Result:
        return "An owned result is discarded without being destroyed, bound for scoped cleanup, transferred, or returned."
    case .Ownership_Unreleased_Local:
        return "An owned local can reach the end of its scope without cleanup or ownership transfer."
    case .Ownership_Use_After_Transfer:
        return "A value is used after its ownership was destroyed, returned, stored, moved, or transferred to a consuming call."
    case .Ownership_Overwrite:
        return "Assignment can replace a live owned value before its cleanup or ownership transfer."
    case .Ownership_Borrowed_Escape:
        return "A borrowed value escapes its owner or is used after the owner can no longer be live."
    case .Ownership_Delete_Borrowed:
        return "Cleanup is attempted on a borrowed value; clean up the owner instead or create an owned copy."
    case .Ownership_Defer_In_Loop:
        return "A defer inside a loop runs when the surrounding scope exits, not at the end of each iteration."
    case .Ownership_Automatic_Cleanup_Skipped:
        return "The compiler cannot prove that automatic cleanup is safe across all relevant ownership and control-flow paths."
    case .Repl_Unretained_Lifecycle:
        return "The REPL can evaluate this native result but cannot safely retain it as a persistent recent value."
    }
    return "A compiler warning without a more specific diagnostic category."
}

compile_warning_code_from_text :: proc(
    text: string,
) -> (Compile_Warning_Code, bool) {
    switch text {
    case "KV0000", "general-warning":
        return .General, true
    case "KVO001", "discarded-owned-result":
        return .Ownership_Discarded_Result, true
    case "KVO002", "unreleased-owned-local":
        return .Ownership_Unreleased_Local, true
    case "KVO003", "use-after-ownership-transfer":
        return .Ownership_Use_After_Transfer, true
    case "KVO004", "overwrite-before-cleanup":
        return .Ownership_Overwrite, true
    case "KVO005", "invalid-borrow-lifetime":
        return .Ownership_Borrowed_Escape, true
    case "KVO006", "delete-of-borrowed-value":
        return .Ownership_Delete_Borrowed, true
    case "KVO007", "defer-inside-loop":
        return .Ownership_Defer_In_Loop, true
    case "KVO008", "automatic-cleanup-not-proven":
        return .Ownership_Automatic_Cleanup_Skipped, true
    case "KVR001", "unretained-repl-result":
        return .Repl_Unretained_Lifecycle, true
    }
    return .General, false
}

compile_warning_code_text :: proc(code: Compile_Warning_Code) -> string {
    switch code {
    case .General:
        return "KV0000"
    case .Ownership_Discarded_Result:
        return "KVO001"
    case .Ownership_Unreleased_Local:
        return "KVO002"
    case .Ownership_Use_After_Transfer:
        return "KVO003"
    case .Ownership_Overwrite:
        return "KVO004"
    case .Ownership_Borrowed_Escape:
        return "KVO005"
    case .Ownership_Delete_Borrowed:
        return "KVO006"
    case .Ownership_Defer_In_Loop:
        return "KVO007"
    case .Ownership_Automatic_Cleanup_Skipped:
        return "KVO008"
    case .Repl_Unretained_Lifecycle:
        return "KVR001"
    }
    return "KV0000"
}

format_eval_compile_warning :: proc(path, source, eval_source: string, warning: Compile_Warning) -> string {
    if warning.span.source == .Eval {
        label := "<eval>"
        if path != "" {
            label = fmt.tprintf("%s:<eval>", path)
        }
        return format_compile_warning(label, eval_source, warning)
    }
    return format_compile_warning(path, source, warning)
}

clone_compile_error :: proc(err: Compile_Error, allocator := context.allocator) -> Compile_Error {
    cloned := err
    if cloned.message != "" {
        cloned.message = strings.clone(cloned.message, allocator)
    }
    if cloned.source_path != "" {
        cloned.source_path = strings.clone(cloned.source_path, allocator)
    }
    // Package source text is borrowed and can belong to a temporary arena.
    // Keep the path and reload the file when formatting after compilation.
    cloned.source_file = ""
    return cloned
}

compile_error_delete :: proc(err: ^Compile_Error, allocator := context.allocator) {
    if err.message != "" {
        delete(err.message, allocator)
    }
    if err.source_path != "" {
        delete(err.source_path, allocator)
    }
    err^ = {}
}

clone_source_map_entry :: proc(entry: Source_Map_Entry, allocator := context.allocator) -> Source_Map_Entry {
    cloned := entry
    if cloned.source_path != "" {
        cloned.source_path = strings.clone(cloned.source_path, allocator)
    }
    return cloned
}

source_map_slice_delete :: proc(entries: [dynamic]Source_Map_Entry, allocator := context.allocator) {
    for entry in entries {
        if entry.source_path != "" {
            delete(entry.source_path, allocator)
        }
    }
    delete(entries)
}

clone_compile_warning :: proc(warning: Compile_Warning, allocator := context.allocator) -> Compile_Warning {
    cloned := warning
    if cloned.message != "" {
        cloned.message = strings.clone(cloned.message, allocator)
    }
    if cloned.source_path != "" {
        cloned.source_path = strings.clone(cloned.source_path, allocator)
    }
    return cloned
}

compile_warning_slice_delete :: proc(warnings: [dynamic]Compile_Warning, allocator := context.allocator) {
    for warning in warnings {
        if warning.message != "" {
            delete(warning.message, allocator)
        }
        if warning.source_path != "" {
            delete(warning.source_path, allocator)
        }
    }
    delete(warnings)
}

format_source_map :: proc(entries: []Source_Map_Entry) -> string {
    builder := strings.builder_make()
    defer strings.builder_destroy(&builder)
    strings.write_string(&builder, "generated_start generated_end source_start source_end\n")
    for entry in entries {
        fmt.sbprintf(
            &builder,
            "%d %d %d %d\n",
            entry.generated_start_line,
            entry.generated_end_line,
            entry.source_span.start,
            entry.source_span.end,
        )
    }
    return strings.clone(strings.to_string(builder))
}

source_map_entry_for_generated_line :: proc(entries: []Source_Map_Entry, line: int) -> (Source_Map_Entry, bool) {
    return source_map_entry_for_generated_location(entries, line, 0)
}

source_map_path_for_generated_location :: proc(entries: []Source_Map_Entry, line, column: int) -> (string, bool) {
    best_path := ""
    best_width := 0
    found := false
    for entry in entries {
        if entry.source_path == "" ||
           line < entry.generated_start_line ||
           line > entry.generated_end_line {
            continue
        }
        if column > 0 && entry.generated_start_column > 0 {
            if column < entry.generated_start_column ||
               (entry.generated_end_column > 0 && column > entry.generated_end_column) {
                continue
            }
        }
        width := entry.generated_end_line - entry.generated_start_line
        if !found || width < best_width {
            best_path = entry.source_path
            best_width = width
            found = true
        }
    }
    return best_path, found
}

source_map_entry_for_generated_location :: proc(entries: []Source_Map_Entry, line, column: int) -> (Source_Map_Entry, bool) {
    best: Source_Map_Entry
    found := false
    best_column_constrained := false
    best_generated_width := 0
    best_column_width := 0
    best_source_width := 0
    for entry in entries {
        if line < entry.generated_start_line || line > entry.generated_end_line {
            continue
        }
        column_constrained := column > 0 && entry.generated_start_column > 0
        if column_constrained {
            if column < entry.generated_start_column {
                continue
            }
            if entry.generated_end_column > 0 && column > entry.generated_end_column {
                continue
            }
        }
        generated_width := entry.generated_end_line - entry.generated_start_line
        column_width := 0
        if entry.generated_start_column > 0 && entry.generated_end_column > 0 {
            column_width = entry.generated_end_column - entry.generated_start_column
        }
        source_width := entry.source_span.end - entry.source_span.start
        if !found ||
           (column_constrained && !best_column_constrained) ||
           (column_constrained == best_column_constrained &&
            column_constrained && column_width < best_column_width) ||
           (column_constrained == best_column_constrained &&
            column_width == best_column_width &&
            generated_width < best_generated_width) ||
           (column_constrained == best_column_constrained &&
            column_width == best_column_width &&
            generated_width == best_generated_width &&
            source_width < best_source_width) ||
           (!column_constrained && !best_column_constrained &&
            generated_width < best_generated_width) ||
           (!column_constrained && !best_column_constrained &&
            generated_width == best_generated_width &&
            source_width < best_source_width) {
            best = entry
            found = true
            best_column_constrained = column_constrained
            best_generated_width = generated_width
            best_column_width = column_width
            best_source_width = source_width
        }
    }
    return best, found
}
