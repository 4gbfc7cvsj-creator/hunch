import Foundation
import HunchCore

/// What the app decided about a request's result, added to its diagnostic record. All calls are
/// no-ops while the console window is closed (the recorder is off).
enum DiagnosticNotes {
    /// Sets the "shown to you" line of the newest record for request `id` unless the engine already
    /// settled it (a suppression), and adds `note` when given.
    static func judge(_ id: RequestID, _ fate: DiagnosticFate, note: String? = nil) {
        guard DiagnosticRecorder.shared.isEnabled else { return }
        DiagnosticRecorder.shared.update(requestKey: id.raw) { record in
            if record.fate == .pending { record.fate = fate }
            if let note { record.note = note }
        }
    }

    /// A finished result: shown, or not drawn and why.
    static func judge(_ id: RequestID, text: String?, displayed: Bool, late: Bool, shown: String?) {
        guard DiagnosticRecorder.shared.isEnabled, let text else { return }   // suppressed: the engine's record already says why
        if displayed {
            judge(id, .shown(shown ?? text))
        } else if late {
            judge(id, .notDisplayed("a newer request had taken over and what you typed since no longer matched it"))
        } else {
            judge(id, .notDisplayed("by the time it was ready the field or the caret had changed, so it was not drawn"))
        }
    }
}
