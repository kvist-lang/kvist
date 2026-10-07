package kvist

import "base:runtime"
import "core:fmt"
import "core:os"
import "core:sort"
import "core:strings"

// References are indexed from source, before expansion, so editor locations
// remain useful even when a source file cannot be compiled yet.
Reference_Options :: struct {
    root: string,
    line, column: int, // One-based byte column, as in compiler diagnostics.
    source_path: string, // Optional read-only overlay for the input file.
}

Reference_File :: struct {
    path, source, namespace: string,
    forms: [dynamic]CST_Top_Form,
    imports: map[string]string,
    referred: map[string]string,
}

Reference_Binding :: struct {name, key: string}
Reference_Occurrence :: struct {
    file: ^Reference_File,
    name, key: string,
    span: Span,
    declaration: bool,
}
Reference_Index :: struct {
    globals: map[string]bool,
    imports, referred: map[string]string,
    occurrences: [dynamic]Reference_Occurrence,
    bindings: [dynamic]Reference_Binding,
    file: ^Reference_File,
}

reference_absolute_path :: proc(path: string) -> string {
    absolute, err := os.get_absolute_path(path, context.allocator)
    if err != nil {
        candidate := path
        if !os.is_absolute_path(candidate) {
            cwd, cwd_err := os.get_working_directory(context.allocator)
            if cwd_err == nil { candidate, _ = os.join_path({cwd, path}, context.allocator) }
        }
        absolute, _ = os.clean_path(candidate, context.allocator)
    }
    trimmed := strings.trim_right(absolute, "/\\")
    return absolute if len(trimmed) == 0 else trimmed
}

reference_project_root :: proc(path: string) -> string {
    dir, _ := os.split_path(path)
    fallback := dir
    for dir != "" {
        git_path, _ := os.join_path({dir, ".git"}, context.allocator)
        if os.exists(git_path) { return dir }
        parent, _ := os.split_path(dir)
        parent = strings.trim_right(parent, "/\\")
        if parent == dir { break }
        dir = parent
    }
    return fallback
}

reference_collect_paths :: proc(dir: string, paths: ^[dynamic]string) -> bool {
    entries, err := os.read_directory_by_path(dir, -1, context.allocator)
    if err != nil { return false }
    for entry in entries {
        // Never recurse into links, generated output, caches or worktrees.
        if strings.has_prefix(entry.name, ".") || entry.name == "build" ||
           entry.name == "dist" || entry.name == "node_modules" ||
           strings.has_suffix(entry.name, ".packages") { continue }
        path, join_err := os.join_path({dir, entry.name}, context.allocator)
        if join_err != nil { continue }
        if entry.type == .Directory {
            reference_collect_paths(path, paths)
        } else if entry.type == .Regular && strings.has_suffix(entry.name, ".kvist") {
            append(paths, reference_absolute_path(path))
        }
    }
    return true
}

reference_package_name :: proc(forms: []CST_Top_Form) -> string {
    for top in forms {
        if decl_head_name(top.form) == "package" && len(top.form.items) == 2 {
            return top.form.items[1].text
        }
    }
    return ""
}

reference_namespace :: proc(path: string, package_name := "") -> string {
    if os.is_dir(path) { return reference_absolute_path(path) }
    dir, _ := os.split_path(path)
    _, dir_name := os.split_path(strings.trim_right(dir, "/\\"))
    anchors := [?]string{"main.kvist", fmt.tprintf("%s.kvist", dir_name)}
    for name in anchors {
        anchor, _ := os.join_path({dir, name}, context.allocator)
        if !os.exists(anchor) { continue }
        if package_name != "" {
            data, err := os.read_entire_file_from_path(anchor, context.allocator)
            if err != nil { continue }
            forms, _, ok := read_kvist_top_forms(string(data), anchor)
            if !ok || reference_package_name(forms[:]) != package_name { continue }
        }
        return reference_absolute_path(dir)
    }
    // Standalone programs beside one another are distinct package contexts.
    return reference_absolute_path(path)
}

reference_name :: proc(text: string) -> string {
    return strings.trim_suffix(text, ":")
}

reference_query_name :: proc(text: string) -> string {
    name := reference_name(text)
    separator := strings.index_any(name, "./")
    if separator > 0 { return fmt.tprintf("%s/%s", name[:separator], name[separator+1:]) }
    return name
}

reference_global_key :: proc(namespace, name: string) -> string {
    return fmt.tprintf("%s\t%s", namespace, reference_name(name))
}

reference_decl_head :: proc(head: string) -> bool {
    switch head {
    case "def", "def-", "defvar", "defvar-", "defconst", "defconst-",
         "defn", "defn-", "defmacro", "defmacro-", "defstruct", "defstruct-",
         "defenum", "defenum-", "defunion", "defunion-", "defiter", "defiter-",
         "deftransform", "deftransform-":
        return true
    }
    return false
}

reference_prepare_file :: proc(index: ^Reference_Index, file: ^Reference_File) {
    file.imports = make(map[string]string)
    file.referred = make(map[string]string)
    for top in file.forms {
        form := top.form
        head := decl_head_name(form)
        if reference_decl_head(head) && len(form.items) > 1 {
            index.globals[reference_global_key(file.namespace, form.items[1].text)] = true
        }
        if head != "import" { continue }
        alias, path := "", ""
        if len(form.items) == 2 && form.items[1].kind == .String {
            path = import_path_text(form.items[1])
            alias = import_default_alias(path)
        } else if entry, ok := import_entry_from_form(form); ok {
            alias, path = entry.alias, entry.path
        }
        if alias == "" { continue }
        namespace := path // Odin and unresolved imports retain a stable identity.
        if resolved, _, ok := resolve_source_import_path(file.path, path); ok {
            namespace = reference_namespace(reference_absolute_path(resolved))
        }
        file.imports[alias] = namespace
        index.imports[reference_global_key(file.namespace, alias)] = namespace
        for name in source_import_refer_names(form) {
            file.referred[name] = reference_global_key(namespace, name)
            index.referred[reference_global_key(file.namespace, name)] = file.referred[name]
        }
    }
}

reference_resolve :: proc(index: ^Reference_Index, text: string) -> string {
    name := reference_name(text)
    for i := len(index.bindings)-1; i >= 0; i -= 1 {
        if index.bindings[i].name == name { return index.bindings[i].key }
    }
    separator := strings.index_any(name, "./")
    if separator > 0 {
        // A local object's member access also refers to the receiver binding.
        for i := len(index.bindings)-1; i >= 0; i -= 1 {
            if index.bindings[i].name == name[:separator] {
                return index.bindings[i].key
            }
        }
        if namespace, ok := index.file.imports[map_name(name[:separator])]; ok {
            return reference_global_key(namespace, name[separator+1:])
        }
        if namespace, ok := index.imports[reference_global_key(index.file.namespace, map_name(name[:separator]))]; ok {
            return reference_global_key(namespace, name[separator+1:])
        }
        key := reference_global_key(index.file.namespace, name[:separator])
        if index.globals[key] { return key }
    }
    key := reference_global_key(index.file.namespace, name)
    if index.globals[key] { return key }
    if referred, ok := index.file.referred[name]; ok { return referred }
    if referred, ok := index.referred[key]; ok { return referred }
    return fmt.tprintf("builtin\t%s", name)
}

reference_add :: proc(index: ^Reference_Index, form: CST_Form, key: string, declaration := false) {
    if form.kind != .Symbol || form.text == "" || form.text == "_" || form.text == "&" { return }
    append(&index.occurrences, Reference_Occurrence{
        file = index.file, name = reference_name(form.text), key = key,
        span = form.span, declaration = declaration,
    })
}

reference_bind :: proc(index: ^Reference_Index, form: CST_Form) {
    if form.kind == .Symbol {
        name := reference_name(form.text)
        if name == "_" || name == "&" { return }
        key := fmt.tprintf("%s\t%d\t%s", index.file.path, form.span.start, name)
        append(&index.bindings, Reference_Binding{name, key})
        reference_add(index, form, key, true)
    } else if form.kind == .Vector {
        for item in form.items { reference_bind(index, item) }
    } else if form.kind == .Brace {
        // EDN destructuring: :keys/:syms/:strs, :as and explicit local/key pairs.
        i := 0
        for i+1 < len(form.items) {
            key, value := form.items[i], form.items[i+1]
            if key.kind == .Keyword {
                if key.text == ":keys" || key.text == ":syms" || key.text == ":strs" || key.text == ":as" {
                    reference_bind(index, value)
                }
            } else { reference_bind(index, key) }
            i += 2
        }
    }
}

reference_walk_params :: proc(index: ^Reference_Index, form: CST_Form, macro_params: bool) {
    if macro_params {
        reference_bind(index, form)
        return
    }
    i := 0
    for i < len(form.items) {
        _, _, type_start, typed := typed_name_parts(form.items[:], i)
        if !typed { reference_bind(index, form.items[i]); i += 1; continue }
        _, next, _, parsed := parse_type_text_from_forms(form.items[:], type_start)
        if !parsed || next <= type_start { next = min(type_start+1, len(form.items)) }
        for item in form.items[type_start:next] { reference_walk(index, item) }
        reference_bind(index, form.items[i])
        i = next
        if i+1 < len(form.items) && (form.items[i].text == ":default" || form.items[i].text == "=") {
            reference_walk(index, form.items[i+1])
            i += 2
        }
    }
}

reference_walk_bindings :: proc(index: ^Reference_Index, form: CST_Form) {
    bindings, _, parsed := parse_let_bindings(form)
    if !parsed { return }
    for binding in bindings {
        reference_walk_binding(index, form, binding)
    }
}

reference_walk_binding :: proc(index: ^Reference_Index, form: CST_Form, binding: Binding) {
    for item in form.items {
        if item.span.start >= binding.target_span.end && item.span.end <= binding.value.span.start {
            reference_walk(index, item)
        }
    }
    // Initializers see previous bindings, but not their own new binding.
    reference_walk(index, binding.value)
    for item in form.items {
        if item.span.start == binding.target_span.start {
            reference_walk_pattern_defaults(index, item)
            reference_bind(index, item)
            break
        }
    }
    if binding.defer_with_cleanup { reference_walk(index, binding.cleanup) }
}

reference_walk_pattern_defaults :: proc(index: ^Reference_Index, form: CST_Form) {
    if form.kind == .Brace {
        for i := 0; i+1 < len(form.items); i += 2 {
            if form.items[i].text == ":or" {
                defaults := form.items[i+1]
                for j := 1; j < len(defaults.items); j += 2 { reference_walk(index, defaults.items[j]) }
            } else { reference_walk_pattern_defaults(index, form.items[i]) }
        }
    } else if form.kind == .Vector {
        for item in form.items { reference_walk_pattern_defaults(index, item) }
    }
}

reference_walk_symbol :: proc(index: ^Reference_Index, form: CST_Form) {
    if !strings.contains_any(form.text, "[]^") {
        reference_add(index, form, reference_resolve(index, form.text))
        return
    }
    // Compact native types are single reader symbols (e.g. []User,
    // ^model.User, map[string]User). Index their named components at their
    // original byte offsets, without pretending the whole type is a name.
    start := 0
    for i := 0; i <= len(form.text); i += 1 {
        if i == len(form.text) || strings.index_byte("[]^#", form.text[i]) >= 0 {
            if i > start && !is_digit(form.text[start]) {
                component := form
                component.text = form.text[start:i]
                component.span.start = form.span.start+start
                component.span.end = form.span.start+i
                reference_add(index, component, reference_resolve(index, component.text))
            }
            start = i+1
        }
    }
}

reference_walk_unquotes :: proc(index: ^Reference_Index, form: CST_Form, depth := 1) {
    head := decl_head_name(form)
    next_depth := depth
    if head == "quasiquote" { next_depth += 1 }
    if head == "unquote" || head == "splice" {
        if depth == 1 {
            for item in form.items[1:] { reference_walk(index, item) }
            return
        }
        next_depth -= 1
    }
    for item in form.items { reference_walk_unquotes(index, item, next_depth) }
}

reference_walk :: proc(index: ^Reference_Index, form: CST_Form) {
    if form.kind == .Symbol {
        reference_walk_symbol(index, form)
        return
    }
    if form.kind != .List {
        for item in form.items { reference_walk(index, item) }
        return
    }
    if len(form.items) == 0 { return }
    head := decl_head_name(form)
    if head == "__kvist_field" {
        // Postfix fields on expressions are reader-generated lists. The field
        // name is a member selector, not a use of a same-named local/global.
        if len(form.items) > 1 { reference_walk(index, form.items[1]) }
        return
    }
    if head == "__kvist_index" || head == "__kvist_slice" {
        for item in form.items[1:] { reference_walk(index, item) }
        return
    }
    if head == "quasiquote" {
        for item in form.items[1:] { reference_walk_unquotes(index, item) }
        return
    }
    if head == "package" || head == "import" || head == "quote" || head == "odin" || head == "@exports" { return }
    scope_start := len(index.bindings)
    defer resize(&index.bindings, scope_start)
    start := 0
    if reference_decl_head(head) && len(form.items) > 1 {
        reference_add(index, form.items[0], reference_resolve(index, head))
        reference_add(index, form.items[1], reference_global_key(index.file.namespace, form.items[1].text), true)
        start = 2
    }
    if head == "defn" || head == "defn-" || head == "defmacro" || head == "defmacro-" || head == "defiter" || head == "defiter-" || head == "fn" {
        if head == "fn" { reference_walk(index, form.items[0]); start = 1 }
        for start < len(form.items) && form.items[start].kind != .Vector {
            reference_walk(index, form.items[start]); start += 1
        }
        if start < len(form.items) {
            reference_walk_params(index, form.items[start], head == "defmacro" || head == "defmacro-")
            start += 1
        }
    } else if head == "let" || head == "when-let" || head == "if-let" || head == "when-ok" || head == "if-ok" {
        reference_walk(index, form.items[0])
        start = 2
        if head == "if-let" || head == "if-ok" {
            if len(form.items) > 1 {
                bindings, _, parsed := parse_let_bindings(form.items[1])
                if parsed {
                    for binding in bindings {
                        reference_walk_binding(index, form.items[1], binding)
                        // The macros place the failure branch inside each
                        // successive result binding's scope.
                        if len(form.items) > 3 { reference_walk(index, form.items[3]) }
                    }
                }
            }
            if len(form.items) > 2 { reference_walk(index, form.items[2]) }
            return
        }
        if len(form.items) > 1 { reference_walk_bindings(index, form.items[1]) }
    } else if head == "for" && len(form.items) > 1 && form.items[1].kind == .Vector {
        reference_walk(index, form.items[0])
        vector := form.items[1]
        count := len(vector.items)
        for item, i in vector.items { if item.kind == .Keyword { count = i; break } }
        if count >= 2 {
            for item in vector.items[count-1:] { reference_walk(index, item) }
            for item in vector.items[:count-1] { reference_bind(index, item) }
        }
        start = 2
    } else if head == "defstruct" || head == "defstruct-" || head == "defenum" || head == "defenum-" || head == "defunion" || head == "defunion-" {
        // Member declarations aren't references to same-named globals.
        for start < len(form.items) {
            vector := form.items[start]
            if vector.kind == .Vector {
                i := 0
                for i < len(vector.items) {
                    _, _, type_start, typed := typed_name_parts(vector.items[:], i)
                    if typed {
                        _, next, _, parsed := parse_type_text_from_forms(vector.items[:], type_start)
                        if !parsed { next = min(type_start+1, len(vector.items)) }
                        for item in vector.items[type_start:next] { reference_walk(index, item) }
                        i = next
                    } else { i += 1 }
                }
            }
            start += 1
        }
        return
    }
    for item in form.items[start:] { reference_walk(index, item) }
}

// Output uses the same location prefix as `kvist xref`, followed by the actual
// spelling and source line. All returned strings belong to the caller.
references_path :: proc(path, identifier: string, options := Reference_Options{}) -> (string, Compile_Error, bool) {
    result_allocator := context.allocator
    temp_scope := runtime.default_temp_allocator_temp_begin()
    defer runtime.default_temp_allocator_temp_end(temp_scope)
    context.allocator = context.temp_allocator
    defer context.allocator = result_allocator

    input := reference_absolute_path(path)
    root := reference_project_root(input) if options.root == "" else reference_absolute_path(options.root)
    paths: [dynamic]string
    if !reference_collect_paths(root, &paths) {
        return "", Compile_Error{message = strings.clone("could not read reference search root", result_allocator)}, false
    }
    if !contains_text(paths[:], input) { append(&paths, input) }
    sort.quick_sort(paths[:])
    files: [dynamic]Reference_File
    for file_path in paths {
        read_path := file_path
        if file_path == input && options.source_path != "" { read_path = options.source_path }
        data, read_err := os.read_entire_file_from_path(read_path, context.allocator)
        if read_err != nil {
            if file_path == input { return "", Compile_Error{message = strings.clone("could not read reference input", result_allocator)}, false }
            continue
        }
        source := string(data)
        forms, err, ok := read_kvist_top_forms(source, file_path)
        if !ok {
            if file_path == input { return "", clone_compile_error(err, result_allocator), false }
            continue // Unfinished unrelated files shouldn't disable navigation.
        }
        append(&files, Reference_File{path = file_path, source = source, forms = forms, namespace = reference_namespace(file_path, reference_package_name(forms[:]))})
    }
    index := Reference_Index{
        globals = make(map[string]bool),
        imports = make(map[string]string),
        referred = make(map[string]string),
    }
    for &file in files { reference_prepare_file(&index, &file) }
    input_file: ^Reference_File
    for &file in files {
        index.file = &file
        if file.path == input { input_file = &file }
        for top in file.forms { reference_walk(&index, top.form) }
    }
    if input_file == nil { return "", Compile_Error{message = strings.clone("reference input was not indexed", result_allocator)}, false }
    index.file = input_file
    keys := make(map[string]bool)
    keys[reference_resolve(&index, identifier)] = true
    if options.line > 0 {
        clear(&keys)
        found := false
        for occurrence in index.occurrences {
            if occurrence.file != input_file { continue }
            line, column, _, _ := source_position(input_file.source, occurrence.span.start)
            if line == options.line && column <= options.column && options.column < column+occurrence.span.end-occurrence.span.start &&
               reference_query_name(occurrence.name) == reference_query_name(identifier) {
                keys[occurrence.key] = true
                found = true
            }
        }
        if !found { return "", Compile_Error{message = strings.clone("no symbol at the requested reference position", result_allocator)}, false }
    }
    builder := strings.builder_make()
    sort.quick_sort_proc(index.occurrences[:], proc(a, b: Reference_Occurrence) -> int {
        if a.file.path < b.file.path { return -1 }
        if a.file.path > b.file.path { return 1 }
        if a.span.start < b.span.start { return -1 }
        if a.span.start > b.span.start { return 1 }
        return 0
    })
    seen := make(map[string]bool)
    for occurrence in index.occurrences {
        if occurrence.declaration || !keys[occurrence.key] { continue }
        location_key := fmt.tprintf("%s:%d", occurrence.file.path, occurrence.span.start)
        if seen[location_key] { continue }
        seen[location_key] = true
        line, column, start, end := source_position(occurrence.file.source, occurrence.span.start)
        text := strings.trim_space(occurrence.file.source[start:end])
        fmt.sbprintf(&builder, "%s:%d:%d\t%s\t%s\n", occurrence.file.path, line, column, occurrence.name, text)
    }
    return strings.clone(strings.to_string(builder), result_allocator), {}, true
}
