import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerTextView: UIViewRepresentable {
    @Binding var text: String
    @Binding var selection: NSRange
    let handoffID: UUID?
    let handoffRole: ComposerTextEditorHandoffRole
    var isEditable: Bool
    var focusRequest: UUID?
    var onFocusRequestFulfilled: ((UUID) -> Void)?
    var onPasteAttachmentEvent: (ComposerPasteEvent) -> Void
    var isScrollEnabled: Bool
    @Binding var contentHeight: CGFloat
    var onResizePanChanged: (CGFloat) -> Void
    var onResizePanEnded: (CGFloat, CGFloat) -> Void
    var onResizePanCancelled: () -> Void

    func makeUIView(context: Context) -> ComposerTextViewContainer {
        let container = ComposerTextViewContainer()
        installActivation(on: container, coordinator: context.coordinator)
        container.activateIfPossible()
        return container
    }

    func updateUIView(_ container: ComposerTextViewContainer, context: Context) {
        installActivation(on: container, coordinator: context.coordinator)
        container.activateIfPossible()
    }

    static func dismantleUIView(
        _ container: ComposerTextViewContainer,
        coordinator _: Coordinator
    ) {
        container.activation = nil
        ComposerTextViewHandoffRegistry.release(container)
    }

    private func installActivation(
        on container: ComposerTextViewContainer,
        coordinator: Coordinator
    ) {
        container.activation = { [self, weak container, weak coordinator] in
            guard let container, let coordinator else { return }
            let view: HeightReportingTextView?
            switch handoffRole {
            case .none:
                // The canonical route outlives NewChatFlow. If SwiftUI updates
                // this representable before the coordinator's synchronous
                // settle hook, adopt the existing editor instead of stacking
                // a second local UITextView over it.
                view =
                    container.localEditor
                    ?? ComposerTextViewHandoffRegistry.retirePromotionEditor(
                        ownedBy: container
                    )
                    ?? makeEditor()
                container.localEditor = view
                if let view, view.superview !== container {
                    container.addSubview(view)
                }
            case .promotionSource:
                if let handoffID {
                    view = ComposerTextViewHandoffRegistry.attachSource(
                        id: handoffID,
                        to: container,
                        makeEditor: makeEditor
                    )
                } else {
                    view = container.localEditor ?? makeEditor()
                    container.localEditor = view
                    if let view, view.superview !== container {
                        container.addSubview(view)
                    }
                }
            case .promotionDestination:
                guard let handoffID else { return }
                view = ComposerTextViewHandoffRegistry.attachDestination(
                    id: handoffID,
                    to: container
                )
            }
            guard let view else { return }
            configure(view, coordinator: coordinator)
            container.setNeedsLayout()
        }
    }

    private func makeEditor() -> HeightReportingTextView {
        let view = HeightReportingTextView()
        view.backgroundColor = .clear
        view.font = .preferredFont(forTextStyle: .body)
        view.adjustsFontForContentSizeCategory = true
        view.textContainerInset = UIEdgeInsets(top: 4, left: 0, bottom: 4, right: 0)
        view.textContainer.lineFragmentPadding = 0
        // Prompts are code-adjacent — no auto-capitalized first letters.
        view.autocapitalizationType = .none
        // A plain UITextView implicitly accepts only strings. Declare the two
        // attachment representations as pasteable too, then let the paste
        // delegate consume them without inserting rich text into the prompt.
        view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
            UTType.plainText.identifier,
            UTType.fileURL.identifier,
            UTType.image.identifier,
        ])
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        // Height flows from the view's own layout, not from updateUIView: a
        // freshly (re)mounted composer has zero width until UIKit lays it
        // out, so measuring during the SwiftUI update reported nothing and a
        // restored draft sat at the minimum height until the next keystroke.
        return view
    }

    private func configure(_ view: HeightReportingTextView, coordinator: Coordinator) {
        coordinator.isApplyingSwiftUIUpdate = true
        defer { coordinator.isApplyingSwiftUIUpdate = false }
        view.delegate = coordinator
        view.pasteDelegate = coordinator
        view.onContentHeightChange = { [binding = $contentHeight] height in
            // Defer: layout can run inside a view update.
            Task { @MainActor in
                binding.wrappedValue = height
            }
        }
        view.onPasteAttachmentEvent = onPasteAttachmentEvent
        // Only push text the view doesn't already have (a restored draft, a
        // send clearing the field) — and never while the keyboard holds an
        // active composition, which a programmatic set would tear down.
        if view.text != text, view.markedTextRange == nil {
            view.text = text
            // The callback defers its binding write, so reporting here —
            // inside a view update — is safe.
            view.reportContentHeight()
        }
        let textLength = (view.text as NSString).length
        if selection.location + selection.length <= textLength,
            view.selectedRange != selection,
            view.markedTextRange == nil
        {
            view.selectedRange = selection
        }
        if view.isEditable != isEditable {
            view.isEditable = isEditable
        }
        view.onFocusRequestFulfilled = onFocusRequestFulfilled
        coordinator.onPasteAttachmentEvent = onPasteAttachmentEvent
        view.requestInitialFocus(focusRequest)
        if view.isScrollEnabled != isScrollEnabled {
            view.isScrollEnabled = isScrollEnabled
        }
        // Closure reassignment never touches keyboard or layout state.
        view.onResizePanChanged = onResizePanChanged
        view.onResizePanEnded = onResizePanEnded
        view.onResizePanCancelled = onResizePanCancelled
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            selection: $selection,
            onPasteAttachmentEvent: onPasteAttachmentEvent
        )
    }

    final class Coordinator: NSObject, UITextViewDelegate, UITextPasteDelegate {
        private let text: Binding<String>
        private let selection: Binding<NSRange>
        var onPasteAttachmentEvent: (ComposerPasteEvent) -> Void
        var isApplyingSwiftUIUpdate = false

        init(
            text: Binding<String>,
            selection: Binding<NSRange>,
            onPasteAttachmentEvent: @escaping (ComposerPasteEvent) -> Void
        ) {
            self.text = text
            self.selection = selection
            self.onPasteAttachmentEvent = onPasteAttachmentEvent
        }

        func textViewDidChange(_ textView: UITextView) {
            text.wrappedValue = textView.text
            selection.wrappedValue = textView.selectedRange
            (textView as? HeightReportingTextView)?.reportContentHeight()
        }

        func textViewDidChangeSelection(_ textView: UITextView) {
            guard !isApplyingSwiftUIUpdate else { return }
            selection.wrappedValue = textView.selectedRange
        }

        /// UIKit supplies item providers only after the user invokes Paste,
        /// preserving the system's paste privacy behavior. Files win over
        /// image previews, matching the macOS composer; plain text delegates
        /// back to UITextView's standard transformation.
        func textPasteConfigurationSupporting(
            _ textPasteConfigurationSupporting: any UITextPasteConfigurationSupporting,
            transform item: any UITextPasteItem
        ) {
            let provider = item.itemProvider
            guard ComposerPasteProviderLoader.canLoadAttachment(from: provider) else {
                item.setDefaultResult()
                return
            }
            ComposerPasteProviderLoader.logInvocation(route: "text-delegate", providers: [provider])
            ComposerPasteProviderLoader.startLoading(
                from: provider,
                onEvent: onPasteAttachmentEvent,
                onCompletion: { success in
                    // Apple permits completing UITextPasteItem from the
                    // provider's asynchronous callback. Do not publish a
                    // cached no-result before we know we consumed the item.
                    if success {
                        item.setNoResult()
                    } else {
                        item.setDefaultResult()
                    }
                }
            )
        }
    }
}
