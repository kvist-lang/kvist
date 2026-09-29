package kvist

import "core:fmt"

ownership_cleanup_skip_reason_text :: proc(
    reason: Ownership_IR_Cleanup_Skip_Reason,
) -> string {
    #partial switch reason {
    case .Captured_By_Closure:
        return "it is captured by a closure"
    case .Stored_Or_Mutable:
        return "it is stored in an aggregate or mutable place"
    case .None:
        return ""
    }
    return ""
}

emit_ownership_plan_diagnostics :: proc(
    e: ^Emitter,
    plan: Ownership_IR_Cleanup_Plan,
) {
    // KVO001-KVO006 and KVO008 are formatted only from ownership-plan facts.
    // KVO007 is the intentionally syntactic defer-in-loop lint.
    for diagnostic in plan.diagnostics {
        #partial switch diagnostic.kind {
        case .Aggregate_Result_Fields_Uncertain:
            emit_coded_warning(
                e,
                fmt.tprintf(
                    "ownership of fields in result from %s cannot be proven consistent across returns and mutations; avoid replacing or escaping owned fields before return, clean up explicitly, or return a consistently owned aggregate",
                    display_head_name(diagnostic.subject),
                ),
                diagnostic.span,
                .Ownership_Automatic_Cleanup_Skipped,
                .Conservative,
            )
        case .Automatic_Cleanup_Skipped:
            reason := ownership_cleanup_skip_reason_text(
                diagnostic.reason,
            )
            if reason == "" {
                continue
            }
            emit_coded_warning(
                e,
                fmt.tprintf(
                    "automatic cleanup for owned result `%s` was skipped because %s; clean it up explicitly after its last use or transfer ownership",
                    diagnostic.subject,
                    reason,
                ),
                diagnostic.span,
                .Ownership_Automatic_Cleanup_Skipped,
                .Conservative,
            )
        case .Use_After_Transfer:
            confidence := Compile_Warning_Confidence.Definite
            if diagnostic.certainty == .Conservative {
                confidence = .Conservative
            }
            emit_coded_warning(
                e,
                fmt.tprintf(
                    "owned local %s is used after ownership transfer",
                    diagnostic.subject,
                ),
                diagnostic.span,
                .Ownership_Use_After_Transfer,
                confidence,
            )
        case .Overwrite_Before_Cleanup:
            confidence := Compile_Warning_Confidence.Definite
            if diagnostic.certainty == .Conservative {
                confidence = .Conservative
            }
            emit_coded_warning(
                e,
                fmt.tprintf(
                    "owned local %s is overwritten before cleanup; delete it or return it before set!",
                    diagnostic.subject,
                ),
                diagnostic.span,
                .Ownership_Overwrite,
                confidence,
            )
        case .Unreleased_Local:
            confidence := Compile_Warning_Confidence.Definite
            if diagnostic.certainty == .Conservative {
                confidence = .Conservative
            }
            emit_coded_warning(
                e,
                fmt.tprintf(
                    "owned local %s is never deleted or returned; add (defer (delete %s)) or return it",
                    diagnostic.subject,
                    diagnostic.subject,
                ),
                diagnostic.span,
                .Ownership_Unreleased_Local,
                confidence,
            )
        case .Discarded_Result:
            message := "owned value is discarded; bind it and clean it up, or return it"
            if diagnostic.subject != "owned value" {
                if diagnostic.supports_scoped_cleanup {
                    message = fmt.tprintf(
                        "owned result from %s is discarded; destructure its results for automatic scoped cleanup, or return it",
                        diagnostic.subject,
                    )
                } else {
                    message = fmt.tprintf(
                        "owned result from %s is discarded; bind it and clean it up, or return it",
                        diagnostic.subject,
                    )
                }
            }
            emit_coded_warning(
                e,
                message,
                diagnostic.span,
                .Ownership_Discarded_Result,
                .Definite,
            )
        case .Borrowed_Escape:
            emit_coded_warning(
                e,
                fmt.tprintf(
                    "borrowed value escapes owner `%s`; `%s` is released when this scope exits, so the borrowed value may become invalid; return an owned copy or keep the value within the owner's lifetime",
                    diagnostic.subject,
                    diagnostic.subject,
                ),
                diagnostic.span,
                .Ownership_Borrowed_Escape,
                .Conservative,
            )
        case .Borrowed_Use_After_Destroy:
            confidence := Compile_Warning_Confidence.Definite
            qualifier := "has been "
            if diagnostic.certainty == .Conservative {
                confidence = .Conservative
                qualifier = "may have been "
            }
            emit_coded_warning(
                e,
                fmt.tprintf(
                    "borrowed value is used after owner `%s` %sdestroyed; move the use before cleanup or create an owned copy",
                    diagnostic.subject,
                    qualifier,
                ),
                diagnostic.span,
                .Ownership_Borrowed_Escape,
                confidence,
            )
        case .Borrowed_Delete_Result:
            confidence := Compile_Warning_Confidence.Definite
            if diagnostic.certainty == .Conservative {
                confidence = .Conservative
            }
            emit_coded_warning(
                e,
                fmt.tprintf(
                    "%s returns a borrowed view; do not delete it, delete the owner instead",
                    diagnostic.subject,
                ),
                diagnostic.span,
                .Ownership_Delete_Borrowed,
                confidence,
            )
        case .Borrowed_Delete_Local:
            confidence := Compile_Warning_Confidence.Definite
            if diagnostic.certainty == .Conservative {
                confidence = .Conservative
            }
            emit_coded_warning(
                e,
                fmt.tprintf(
                    "borrowed local `%s` must not be deleted; delete the owner instead",
                    diagnostic.subject,
                ),
                diagnostic.span,
                .Ownership_Delete_Borrowed,
                confidence,
            )
        }
    }
}
