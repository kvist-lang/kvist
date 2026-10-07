package kvist

import "core:fmt"
import "core:strings"

// Odin instantiates polymorphic procedures after Kvist has chosen lifecycles.
// Give Data-bearing instantiations a concrete Kvist body so binding, argument,
// assignment and return lowering all use the ordinary managed rules.
managed_proc_specialization_for_args :: proc(
    e: ^Emitter, original: ^Proc_Decl, args: []CST_Form,
) -> (^Proc_Decl, bool) {
    if e.captured_proc_specializations == nil {
        return nil, false
    }
    for spec in e.captured_proc_specializations^ {
        if spec.managed_decl == original { return original, true }
    }
    names, types, known := proc_decl_call_type_bindings(e, original, args)
    defer delete(names)
    defer delete(types)
    if !known || len(names) == 0 {
        return nil, false
    }
    managed := false
    for ty in types {
        if type_text_has_data_lifecycle(e, ty) {
            managed = true
        }
    }
    if !managed {
        return nil, false
    }
    candidates := proc_decl_generic_candidates(original)
    defer delete(candidates)
    for candidate in candidates {
        if !generic_param_in_slice(names[:], candidate) {
            return nil, false
        }
    }
    key_builder := strings.builder_make()
    defer strings.builder_destroy(&key_builder)
    strings.write_string(&key_builder, original.name)
    for name, idx in names {
        fmt.sbprintf(&key_builder, "|%s=%s", name, types[idx])
    }
    key := strings.to_string(key_builder)
    for spec in e.captured_proc_specializations^ {
        if spec.managed_decl != nil && spec.managed_key == key {
            return spec.managed_decl, true
        }
    }
    concrete := new(Proc_Decl)
    concrete^ = original^
    concrete.name = strings.clone(fmt.tprintf("%s__kvist_managed_%d", original.name, len(e.captured_proc_specializations^)))
    concrete.params = specialize_params(original.params[:], names[:], types[:])
    concrete.returns = specialize_return_spec(original.returns, names[:], types[:])
    concrete.body = nil
    concrete.where_constraints = nil
    for form in original.body {
        append(&concrete.body, specialize_managed_generic_form(form, names[:], types[:]))
    }
    for form in original.where_constraints {
        append(&concrete.where_constraints, specialize_managed_generic_form(form, names[:], types[:]))
    }
    for &param in concrete.params {
        if type_text_has_data_lifecycle(e, param.ty) { param.ownership = .Default }
    }
    // Register before inspecting calls in the body: recursive specializations
    // must resolve to this stable declaration rather than instantiate again.
    append(e.captured_proc_specializations, Captured_Proc_Specialization{
        original_name = original.name,
        callback_param_index = -1,
        managed_decl = concrete,
        managed_key = strings.clone(key),
    })
    for &param in concrete.params {
        if type_text_has_data_lifecycle(e, param.ty) &&
           body_consumes_data_parameter(e, concrete.body[:], param.name) {
            param.ownership = .Owned
        }
    }
    return concrete, true
}

specialize_managed_generic_form :: proc(form: CST_Form, names, types: []string) -> CST_Form {
    result := clone_cst_form(form)
    specialize_managed_generic_form_in_place(&result, names, types)
    return result
}

specialize_managed_generic_form_in_place :: proc(form: ^CST_Form, names, types: []string, quoted_depth: int = 0) {
    if form.kind == .Symbol && quoted_depth == 0 {
        specialized := substitute_type_names(form.text, names, types)
        delete(form.text)
        form.text = specialized
        return
    }
    if form.kind == .List && len(form.items) > 0 && is_symbol(form.items[0], "quote") {
        return
    }
    if form.kind == .List && len(form.items) > 0 {
        if is_symbol(form.items[0], "quasiquote") {
            for &item in form.items[1:] {
                specialize_managed_generic_form_in_place(&item, names, types, quoted_depth+1)
            }
            return
        }
        if quoted_depth > 0 && (is_symbol(form.items[0], "unquote") || is_symbol(form.items[0], "unquote-splicing")) {
            for &item in form.items[1:] {
                specialize_managed_generic_form_in_place(&item, names, types, quoted_depth-1)
            }
            return
        }
    }
    for &item in form.items {
        specialize_managed_generic_form_in_place(&item, names, types, quoted_depth)
    }
}

delete_managed_proc_specializations :: proc(specs: ^[dynamic]Captured_Proc_Specialization) {
    for spec in specs^ {
        concrete := spec.managed_decl
        if concrete == nil { continue }
        delete(spec.managed_key)
        delete(concrete.name)
        for param in concrete.params { delete(param.ty) }
        delete(concrete.params)
        #partial switch concrete.returns.kind {
        case .Single: delete(concrete.returns.single_ty)
        case .Named:
            for ret in concrete.returns.named { delete(ret.ty) }
            delete(concrete.returns.named)
        }
        for &form in concrete.body { delete_cst_form(&form) }
        delete(concrete.body)
        for &form in concrete.where_constraints { delete_cst_form(&form) }
        delete(concrete.where_constraints)
        free(concrete)
    }
}
