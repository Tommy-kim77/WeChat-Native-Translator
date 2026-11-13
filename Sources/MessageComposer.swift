import AppKit
import SwiftUI

struct ComposerPlacement {
    let id = UUID()
    let range: NSRange
}

struct MessageComposer: NSViewRepresentable {
    var text: String
    var editable = true
    var label: String
    var placement: ComposerPlacement?
    var onEdit: ((String, DraftEdit?, NSRange) -> Void)?
    var onSelection: ((NSRange) -> Void)?
    var navigate: ((UInt16) -> Bool)?
    var submit: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSTextView.scrollableTextView()
        let editor = scroll.documentView as! NSTextView
        editor.delegate = context.coordinator
        editor.isRichText = false
        editor.importsGraphics = false
        editor.isEditable = editable
        editor.allowsUndo = editable
        editor.font = .systemFont(ofSize: NSFont.systemFontSize)
        editor.textContainerInset = NSSize(width: 5, height: 6)
        editor.setAccessibilityLabel(label)
        editor.string = text
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        let coordinator = context.coordinator
        coordinator.composer = self
        guard let editor = scroll.documentView as? NSTextView else { return }
        editor.setAccessibilityLabel(label)
        editor.isEditable = editable
        coordinator.updating = true
        defer { coordinator.updating = false }
        if editor.string != text {
            editor.string = text
            editor.setSelectedRange(NSRange(location: text.utf16.count, length: 0))
        }
        if let placement, placement.id != coordinator.appliedPlacement, Range(placement.range, in: text) != nil {
            coordinator.appliedPlacement = placement.id
            editor.window?.makeFirstResponder(editor)
            editor.setSelectedRange(placement.range)
            editor.scrollRangeToVisible(placement.range)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var composer: MessageComposer
        var appliedPlacement: UUID?
        var updating = false
        private var pendingEdit: DraftEdit?

        init(_ composer: MessageComposer) { self.composer = composer }

        func textDidChange(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            let edit = pendingEdit
            pendingEdit = nil
            composer.onEdit?(editor.string, edit, editor.selectedRange())
        }

        func textView(_ textView: NSTextView, shouldChangeTextIn affectedCharRange: NSRange, replacementString: String?) -> Bool {
            pendingEdit = replacementString.map { DraftEdit(range: affectedCharRange, replacement: $0) }
            return true
        }

        func textViewDidChangeSelection(_ notification: Notification) {
            guard !updating, let editor = notification.object as? NSTextView else { return }
            composer.onSelection?(editor.selectedRange())
        }

        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            guard let event = NSApp.currentEvent, event.type == .keyDown,
                  !textView.hasMarkedText(),
                  event.modifierFlags.intersection([.shift, .option, .command, .control]).isEmpty else { return false }
            if [53, 125, 126].contains(event.keyCode), composer.navigate?(event.keyCode) == true { return true }
            guard [36, 76].contains(event.keyCode) else { return false }
            guard commandSelector == #selector(NSResponder.insertNewline(_:)) ||
                    commandSelector == #selector(NSResponder.insertNewlineIgnoringFieldEditor(_:)) else { return false }
            if !event.isARepeat { composer.submit() }
            return true
        }
    }
}
