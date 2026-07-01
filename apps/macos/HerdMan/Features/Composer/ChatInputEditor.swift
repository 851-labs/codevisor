import SwiftUI
import AppKit

enum ComposerKeyCommand {
    case moveSelectionUp
    case moveSelectionDown
    case acceptSelection
    case dismissSelection
}

/// A multiline text editor where **Return submits** and **Shift+Return inserts a
/// newline**. Grows with its content between `minHeight` and `maxHeight`.
struct ChatInputEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var calculatedHeight: CGFloat
    var minHeight: CGFloat = 24
    var maxHeight: CGFloat = 240
    var onSubmit: () -> Void
    var onKeyCommand: ((ComposerKeyCommand) -> Bool)? = nil
    /// Called once with the underlying text view so callers can move focus to it
    /// (used by the terminal's ⌘J focus handoff).
    var onTextViewReady: ((NSView) -> Void)? = nil

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmittingTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { onSubmit() }
        textView.onKeyCommand = onKeyCommand
        onTextViewReady?(textView)
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: 6)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.textContainer?.widthTracksTextView = true
        textView.textContainer?.lineFragmentPadding = 0

        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.documentView = textView
        context.coordinator.textView = textView
        DispatchQueue.main.async { recalculateHeight(textView) }
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmittingTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = { onSubmit() }
        textView.onKeyCommand = onKeyCommand
        if textView.string != text {
            textView.string = text
        }
        recalculateHeight(textView)
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    private func recalculateHeight(_ textView: NSTextView) {
        guard let layoutManager = textView.layoutManager, let container = textView.textContainer else { return }
        layoutManager.ensureLayout(for: container)
        let used = layoutManager.usedRect(for: container).height + textView.textContainerInset.height * 2
        let clamped = min(max(used, minHeight), maxHeight)
        if abs(clamped - calculatedHeight) > 0.5 {
            DispatchQueue.main.async { calculatedHeight = clamped }
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: ChatInputEditor
        weak var textView: SubmittingTextView?

        init(_ parent: ChatInputEditor) { self.parent = parent }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            parent.recalculateHeight(textView)
        }
    }
}

/// An `NSTextView` that submits on Return and inserts a newline on Shift+Return.
final class SubmittingTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onKeyCommand: ((ComposerKeyCommand) -> Bool)?

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53:
            if onKeyCommand?(.dismissSelection) == true { return }
        case 48:
            if onKeyCommand?(.acceptSelection) == true { return }
        case 125:
            if onKeyCommand?(.moveSelectionDown) == true { return }
        case 126:
            if onKeyCommand?(.moveSelectionUp) == true { return }
        default:
            break
        }
        // 36 = Return, 76 = numeric keypad Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            if event.modifierFlags.contains(.shift) {
                super.keyDown(with: event) // newline
            } else {
                if onKeyCommand?(.acceptSelection) != true {
                    onSubmit?()
                }
            }
            return
        }
        super.keyDown(with: event)
    }
}
