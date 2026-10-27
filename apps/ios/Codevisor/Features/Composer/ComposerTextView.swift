import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct ComposerTextEdit: Equatable {
  let id = UUID()
  let range: NSRange
  let replacement: String
}

struct ComposerTextView: UIViewRepresentable {
  @Binding var text: String
  @Binding var selection: NSRange
  var pendingEdit: ComposerTextEdit? = nil
  let handoffID: UUID?
  let handoffRole: ComposerTextEditorHandoffRole
  var isEditable: Bool
  var focusRequest: UUID?
  var onFocusRequestFulfilled: ((UUID) -> Void)?
  var onPasteAttachmentEvent: (ComposerPasteEvent) -> Void
  var isComposerExpanded: Bool
  @Binding var contentHeight: CGFloat
  var onFocusChange: (Bool) -> Void
  var onResizePanChanged: (CGFloat) -> Void
  var onResizePanEnded: (CGFloat, CGFloat) -> Void
  var onResizePanCancelled: () -> Void
  var onHardwareReturn: (() -> Void)?
  var onHardwareQueue: (() -> Void)?
  var topInset: CGFloat = ComposerBar.editorTopBleed

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
    view.textContainerInset = UIEdgeInsets(top: 4 + topInset, left: 0, bottom: 4, right: 0)
    view.textContainer.lineFragmentPadding = 0
    view.autocapitalizationType = .none
    view.pasteConfiguration = UIPasteConfiguration(acceptableTypeIdentifiers: [
      UTType.plainText.identifier,
      UTType.fileURL.identifier,
      UTType.image.identifier,
    ])
    view.setContentHuggingPriority(.defaultLow, for: .horizontal)
    view.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
    return view
  }

  private func configure(_ view: HeightReportingTextView, coordinator: Coordinator) {
    coordinator.isApplyingSwiftUIUpdate = true
    defer { coordinator.isApplyingSwiftUIUpdate = false }
    view.delegate = coordinator
    view.pasteDelegate = coordinator
    view.onContentHeightChange = { [binding = $contentHeight] height in
      Task { @MainActor in
        binding.wrappedValue = height
      }
    }
    view.onPasteAttachmentEvent = onPasteAttachmentEvent
    if let edit = pendingEdit, coordinator.appliedEditID != edit.id {
      coordinator.appliedEditID = edit.id
      applyUndoably(edit, to: view)
    }
    if view.text != text, view.markedTextRange == nil {
      view.text = text
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
    view.onFocusChange = onFocusChange
    if coordinator.reportedFocus != view.isFirstResponder {
      coordinator.reportedFocus = view.isFirstResponder
      view.reportFocus()
    }
    view.requestInitialFocus(focusRequest)
    view.isComposerExpanded = isComposerExpanded
    view.onResizePanChanged = onResizePanChanged
    view.onResizePanEnded = onResizePanEnded
    view.onResizePanCancelled = onResizePanCancelled
    view.onHardwareReturn = onHardwareReturn
    view.onHardwareQueue = onHardwareQueue
  }

  private func applyUndoably(_ edit: ComposerTextEdit, to view: UITextView) {
    guard view.markedTextRange == nil,
      let start = view.position(from: view.beginningOfDocument, offset: edit.range.location),
      let end = view.position(from: start, offset: edit.range.length),
      let range = view.textRange(from: start, to: end)
    else { return }
    view.undoManager?.beginUndoGrouping()
    view.replace(range, withText: edit.replacement)
    view.undoManager?.endUndoGrouping()
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
    var reportedFocus: Bool?
    var appliedEditID: UUID?

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
      (textView as? HeightReportingTextView)?.textDidChangeByUser()
      guard !isApplyingSwiftUIUpdate else { return }
      text.wrappedValue = textView.text
      selection.wrappedValue = textView.selectedRange
      (textView as? HeightReportingTextView)?.reportContentHeight()
    }

    func scrollViewWillEndDragging(
      _ scrollView: UIScrollView,
      withVelocity _: CGPoint,
      targetContentOffset: UnsafeMutablePointer<CGPoint>
    ) {
      guard let holdingOffset = (scrollView as? HeightReportingTextView)?.resizeHoldingOffset
      else { return }
      targetContentOffset.pointee = holdingOffset
    }

    func textViewDidChangeSelection(_ textView: UITextView) {
      guard !isApplyingSwiftUIUpdate else { return }
      selection.wrappedValue = textView.selectedRange
    }

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
