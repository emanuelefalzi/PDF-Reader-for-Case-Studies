import AppKit
import SwiftUI

/// Real search field: it replaces a SwiftUI `TextField` + `@FocusState`,
/// which, hosted inside a `ToolbarItem` (SPEC §5.1), did not always move the
/// window's real `first responder` when requested from code
/// (`DocumentModel.focusSearch()`, the ⌘F menu command; verified with
/// `NSApp.keyWindow?.firstResponder` in `SearchFieldFocusTests`). It is the
/// same root cause, in a different form, as an earlier unverified
/// AppKit/SwiftUI behavior. `SearchFieldView` keeps a direct reference to
/// the AppKit view and calls `window.makeFirstResponder(_:)` by hand, the
/// same technique already used throughout this codebase for precise focus
/// control (`MarkedNSTextView`, `EditableMarkedNSTextView`, `PDFKitView`).
struct SearchFieldView: NSViewRepresentable {
    let model: DocumentModel

    func makeCoordinator() -> Coordinator {
        Coordinator(model: model)
    }

    func makeNSView(context: Context) -> LelePdfSearchField {
        let field = LelePdfSearchField()
        field.delegate = context.coordinator
        field.placeholderString = String(localized: "Search in chapter")
        field.font = .systemFont(ofSize: 12)
        field.stringValue = model.searchQuery
        (field.cell as? NSSearchFieldCell)?.searchButtonCell = nil
        (field.cell as? NSSearchFieldCell)?.cancelButtonCell = nil
        return field
    }

    func updateNSView(_ nsView: LelePdfSearchField, context: Context) {
        context.coordinator.model = model
        if nsView.stringValue != model.searchQuery {
            nsView.stringValue = model.searchQuery
        }
        // `searchFocusToken` grows on every ⌘F: a change (never the absolute
        // value) is the "one-shot" request to take the REAL focus, not just
        // the SwiftUI one.
        guard context.coordinator.lastFocusToken != model.searchFocusToken else { return }
        context.coordinator.lastFocusToken = model.searchFocusToken
        DispatchQueue.main.async {
            guard let window = nsView.window else { return }
            window.makeFirstResponder(nsView)
            nsView.currentEditor()?.selectAll(nil)
        }
    }

    @MainActor
    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var model: DocumentModel
        var lastFocusToken: Int

        init(model: DocumentModel) {
            self.model = model
            self.lastFocusToken = model.searchFocusToken
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSTextField else { return }
            model.searchQuery = field.stringValue
        }

        /// SPEC §5.10 "↩ goes to the next, ⇧↩ to the previous. Esc closes":
        /// intercepted on the field editor's path (`doCommandBySelector`), the
        /// only reliable spot for an `NSTextField`/`NSSearchField`; an
        /// `override keyDown` on the view itself would not see these keys once
        /// editing has begun (the shared field editor consumes them first).
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.insertNewline(_:)):
                let shift = NSApp.currentEvent?.modifierFlags.contains(.shift) == true
                if shift { model.searchPrevious() } else { model.searchNext() }
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                model.closeSearch()
                return true
            default:
                return false
            }
        }
    }
}

/// `NSSearchField` without the stock magnifier/cancel button
/// (`SearchFieldView.makeNSView` removes them): the app already draws its
/// own magnifier and counter around the field (`SearchBar.swift`), giving the
/// same look as before with the SwiftUI `TextField`.
final class LelePdfSearchField: NSSearchField {}
