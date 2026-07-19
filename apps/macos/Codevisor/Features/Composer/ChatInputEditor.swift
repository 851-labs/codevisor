import SwiftUI
import AppKit

enum ComposerKeyCommand {
    case moveSelectionUp
    case moveSelectionDown
    case acceptSelection
    case dismissSelection
}

/// Attachment-worthy pasteboard content intercepted by the composer's paste.
enum PastedAttachment {
    case fileURL(URL)
    /// PNG-normalized image bytes.
    case image(data: Data, suggestedName: String?)
}

/// A multiline text editor where **Return submits** and **Shift+Return inserts a
/// newline**. Grows with its content between `minHeight` and `maxHeight`.
struct ChatInputEditor: NSViewRepresentable {
    private static let verticalTextInset: CGFloat = 6

    /// Starting at the same height TextKit will report prevents a newly
    /// mounted composer from growing one frame later. Derive it from the
    /// preferred body font so accessibility text sizing stays in sync too.
    static var singleLineHeight: CGFloat {
        NSLayoutManager().defaultLineHeight(
            for: NSFont.preferredFont(forTextStyle: .body)
        ) + verticalTextInset * 2
    }

    @Binding var text: String
    @Binding var calculatedHeight: CGFloat
    var minHeight: CGFloat = Self.singleLineHeight
    var maxHeight: CGFloat = 240
    var onSubmit: () -> Void
    var onKeyCommand: ((ComposerKeyCommand) -> Bool)? = nil
    /// Returns true when the paste was consumed as attachments (file URLs or
    /// image data); false falls through to the normal text paste.
    var onPasteAttachments: (([PastedAttachment]) -> Bool)? = nil
    /// Called once with the underlying text view so callers can move focus to it
    /// (used by the terminal's ⌘J and type-to-focus handoffs).
    var onTextViewReady: ((SubmittingTextView) -> Void)? = nil
    /// Honors SwiftUI `.disabled(...)`: the text view stops accepting edits
    /// (and Return stops submitting) while a send is being accepted.
    @Environment(\.isEnabled) private var isEnabled

    func makeNSView(context: Context) -> NSScrollView {
        let textView = SubmittingTextView()
        textView.delegate = context.coordinator
        textView.onSubmit = { onSubmit() }
        textView.onKeyCommand = onKeyCommand
        textView.onPasteAttachments = onPasteAttachments
        onTextViewReady?(textView)
        textView.string = text
        textView.font = .preferredFont(forTextStyle: .body)
        textView.isRichText = false
        // No automatic formatting in a prompt box: smart quotes/dashes and
        // autocorrect mangle code and identifiers, and these apply even in
        // plain-text views (they follow the system defaults otherwise).
        textView.isAutomaticQuoteSubstitutionEnabled = false
        textView.isAutomaticDashSubstitutionEnabled = false
        textView.isAutomaticTextReplacementEnabled = false
        textView.isAutomaticSpellingCorrectionEnabled = false
        textView.isAutomaticLinkDetectionEnabled = false
        textView.isAutomaticDataDetectionEnabled = false
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 0, height: Self.verticalTextInset)
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
        // Height depends on the wrap width, which SwiftUI only settles after
        // layout — re-measure whenever the text view's width changes.
        textView.postsFrameChangedNotifications = true
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.textViewFrameDidChange(_:)),
            name: NSView.frameDidChangeNotification,
            object: textView
        )
        DispatchQueue.main.async { recalculateHeight(textView) }
        return scroll
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? SubmittingTextView else { return }
        context.coordinator.parent = self
        textView.onSubmit = { onSubmit() }
        textView.onKeyCommand = onKeyCommand
        textView.onPasteAttachments = onPasteAttachments
        textView.isEditable = isEnabled
        if textView.string != text {
            textView.string = text
        }
        // Change-driven: this runs on EVERY SwiftUI invalidation of the
        // composer (including transcript streaming re-renders), and
        // `recalculateHeight` is a full TextKit layout pass of the draft.
        // Only re-measure when the text or wrap width actually changed.
        context.coordinator.recalculateHeightIfNeeded()
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
        /// The text/width the height was last measured for. Guards the
        /// full-layout `recalculateHeight` so it runs once per real change
        /// instead of once per SwiftUI invalidation (and prevents the
        /// keystroke → binding write → update round-trip from laying the
        /// same text out twice).
        private var measuredText: String?
        private var measuredWidth: CGFloat = -1

        init(_ parent: ChatInputEditor) { self.parent = parent }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        func recalculateHeightIfNeeded() {
            guard let textView else { return }
            let width = textView.bounds.width
            guard measuredText != textView.string || abs(measuredWidth - width) > 0.5 else { return }
            recordMeasurement(textView)
            parent.recalculateHeight(textView)
        }

        @objc func textViewFrameDidChange(_ notification: Notification) {
            guard let textView else { return }
            // Height changes are our own doing (the view grows with its
            // content); only a width change re-wraps the text.
            guard abs(measuredWidth - textView.bounds.width) > 0.5 else { return }
            recordMeasurement(textView)
            parent.recalculateHeight(textView)
        }

        private func recordMeasurement(_ textView: NSTextView) {
            measuredText = textView.string
            measuredWidth = textView.bounds.width
        }

        func textDidChange(_ notification: Notification) {
            guard let textView = notification.object as? NSTextView else { return }
            parent.text = textView.string
            recordMeasurement(textView)
            parent.recalculateHeight(textView)
        }

        /// Routes navigation commands to the composer (slash-command menu) via
        /// the standard key-binding pipeline, so arrow keys, Tab, and Escape
        /// steer the menu instead of the text view while it is open.
        func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                return parent.onKeyCommand?(.moveSelectionUp) == true
            case #selector(NSResponder.moveDown(_:)):
                return parent.onKeyCommand?(.moveSelectionDown) == true
            case #selector(NSResponder.insertTab(_:)):
                return parent.onKeyCommand?(.acceptSelection) == true
            case #selector(NSResponder.cancelOperation(_:)):
                return parent.onKeyCommand?(.dismissSelection) == true
            default:
                return false
            }
        }
    }
}

/// An `NSTextView` that submits on Return and inserts a newline on Shift+Return.
/// Menu navigation (arrows, Tab, Escape) is handled by the coordinator's
/// `textView(_:doCommandBy:)`; only Return needs special-casing here because the
/// Shift modifier isn't visible at the command-selector level.
final class SubmittingTextView: NSTextView {
    var onSubmit: (() -> Void)?
    var onKeyCommand: ((ComposerKeyCommand) -> Bool)?
    var onPasteAttachments: (([PastedAttachment]) -> Bool)?

    /// Accept only plain-text drags. NSTextView's default drag registration
    /// includes file URLs/filenames/promises and inserts a dropped file's
    /// *path* as text; narrowing `acceptableDragTypes` (the hook that
    /// `updateDragTypeRegistration()` consults — NSTextView does NOT route
    /// its registration through `registerForDraggedTypes`, so overriding that
    /// is a no-op) leaves the text view unregistered for file drags, so
    /// AppKit routes them past the composer to the session page's attachment
    /// dropzone (`AttachmentDropModifier`) and the file attaches instead.
    override var acceptableDragTypes: [NSPasteboard.PasteboardType] { [.string] }

    /// The app-level Format menu (⌘B/⌘I, alignment, …) exists for the
    /// scratchpad's rich editor. The composer is plain text, but NSTextView
    /// still honors alignment (a paragraph attribute) and font-manager trait
    /// changes (which restyle the WHOLE box in plain-text mode) — so every
    /// formatting action is refused here: the menu items disable while the
    /// composer has focus, and the actions are no-ops if invoked anyway.
    private static let blockedFormatActions: Set<Selector> = [
        #selector(NSText.alignLeft(_:)),
        #selector(NSText.alignCenter(_:)),
        #selector(NSText.alignRight(_:)),
        #selector(NSTextView.alignJustified(_:)),
        #selector(NSText.underline(_:)),
        #selector(NSTextView.outline(_:)),
        #selector(NSTextView.raiseBaseline(_:)),
        #selector(NSTextView.lowerBaseline(_:)),
        NSSelectorFromString("superscript:"),
        NSSelectorFromString("subscript:"),
        NSSelectorFromString("unscript:"),
        #selector(NSTextView.changeFont(_:)),
        NSSelectorFromString("changeAttributes:")
    ]

    override func alignLeft(_ sender: Any?) {}
    override func alignCenter(_ sender: Any?) {}
    override func alignRight(_ sender: Any?) {}
    override func alignJustified(_ sender: Any?) {}
    override func underline(_ sender: Any?) {}
    override func outline(_ sender: Any?) {}
    override func raiseBaseline(_ sender: Any?) {}
    override func lowerBaseline(_ sender: Any?) {}
    override func changeFont(_ sender: Any?) {}

    /// `NSTextView` validates the Edit > Paste command against its own
    /// plain-text readable types before dispatching the action. An image-only
    /// clipboard therefore disables the menu item (and its Command-V key
    /// equivalent), even though `paste(_:)` below knows how to attach it.
    /// Include attachment-worthy content in that validation without teaching
    /// the text view to insert images into its text storage.
    override func validateUserInterfaceItem(_ item: any NSValidatedUserInterfaceItem) -> Bool {
        if let action = item.action, Self.blockedFormatActions.contains(action) {
            return false
        }
        if item.action == #selector(paste(_:)),
           isEditable,
           onPasteAttachments != nil,
           Self.pasteboardContainsAttachments(NSPasteboard.general) {
            return true
        }
        return super.validateUserInterfaceItem(item)
    }

    /// Intercepts pastes carrying files or raw image data (e.g. copied
    /// screenshots) and routes them to the composer as attachments; plain text
    /// falls through to the normal paste.
    override func paste(_ sender: Any?) {
        let attachments = Self.pasteboardAttachments(NSPasteboard.general)
        if !attachments.isEmpty, onPasteAttachments?(attachments) == true {
            return
        }
        super.paste(sender)
    }

    private static func pasteboardAttachments(_ pasteboard: NSPasteboard) -> [PastedAttachment] {
        // File URLs win: a Finder copy also carries the filename as a string,
        // which must not paste as text.
        if let urls = pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL], !urls.isEmpty {
            return urls.map { .fileURL($0) }
        }
        // Raw image data (copied screenshots, images copied from a browser).
        for type in [NSPasteboard.PasteboardType.png, .tiff] {
            guard let data = pasteboard.data(forType: type) else { continue }
            let png = type == .png ? data : pngData(from: data)
            guard let png else { continue }
            return [.image(data: png, suggestedName: nil)]
        }
        return []
    }

    /// Cheap validation path: menu validation runs frequently, so avoid
    /// decoding/converting TIFF data until Paste is actually invoked.
    private static func pasteboardContainsAttachments(_ pasteboard: NSPasteboard) -> Bool {
        if pasteboard.canReadObject(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) {
            return true
        }
        return pasteboard.availableType(from: [.png, .tiff]) != nil
    }

    override func keyDown(with event: NSEvent) {
        // 53 = Escape. Consume it here as well as in the delegate so it can
        // never fall through to NSTextView's default `complete:` behavior.
        if event.keyCode == 53, onKeyCommand?(.dismissSelection) == true {
            return
        }
        // 36 = Return, 76 = numeric keypad Enter.
        if event.keyCode == 36 || event.keyCode == 76 {
            guard isEditable else { return }
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
