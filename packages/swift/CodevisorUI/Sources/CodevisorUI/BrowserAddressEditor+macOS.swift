#if os(macOS)
  import AppKit
  import SwiftUI

  /// A native field editor keeps selection, IME and standard text shortcuts intact.
  /// Its suggestions are a nonactivating child panel, so showing them never takes
  /// keyboard focus away from the address field or resizes the window toolbar.
  public struct BrowserAddressEditor: NSViewRepresentable {
    @Binding var text: String
    @Binding var editing: Bool
    let focusRequest: Int
    let fullAddress: String
    let suggestions: BrowserSuggestions
    let submit: (String) -> Void
    let cancel: () -> Void

    public init(
      text: Binding<String>, editing: Binding<Bool>, focusRequest: Int, fullAddress: String,
      suggestions: BrowserSuggestions, submit: @escaping (String) -> Void, cancel: @escaping () -> Void
    ) {
      _text = text; _editing = editing; self.focusRequest = focusRequest; self.fullAddress = fullAddress
      self.suggestions = suggestions; self.submit = submit; self.cancel = cancel
    }

    public func makeCoordinator() -> Coordinator { Coordinator(self) }
    public func makeNSView(context: Context) -> NSTextField {
      let field = AddressField()
      field.onFocus = { [weak coordinator = context.coordinator] in coordinator?.prepareEditing() }
      field.isBezeled = false
      field.drawsBackground = false
      field.focusRingType = .none
      field.font = .preferredFont(forTextStyle: .body)
      field.usesSingleLineMode = true
      field.maximumNumberOfLines = 1
      field.cell?.wraps = false
      field.cell?.isScrollable = true
      field.lineBreakMode = .byClipping
      field.placeholderString = "Search or enter website name"
      field.setAccessibilityLabel("Website address")
      field.delegate = context.coordinator
      context.coordinator.field = field
      return field
    }
    public func updateNSView(_ field: NSTextField, context: Context) {
      let coordinator = context.coordinator
      coordinator.owner = self
      if field.stringValue != text { field.stringValue = text }
      field.alignment = editing ? .left : .center
      if coordinator.lastFocusRequest != focusRequest, focusRequest > 0 {
        coordinator.lastFocusRequest = focusRequest
        DispatchQueue.main.async { [weak coordinator, weak field] in
          guard let coordinator, coordinator.owner.editing, let field, field.window != nil else { return }
          coordinator.focusAndSelectAll()
        }
      }
      coordinator.updatePanel()
    }
    public static func dismantleNSView(_ field: NSTextField, coordinator: Coordinator) { coordinator.closePanel() }

    @MainActor
    public final class Coordinator: NSObject, NSTextFieldDelegate {
      var owner: BrowserAddressEditor
      weak var field: NSTextField?
      var lastFocusRequest = -1
      var previousInput = ""
      private var panel: NSPanel?
      init(_ owner: BrowserAddressEditor) { self.owner = owner }

      func focusAndSelectAll() {
        guard let field else { return }
        // Calling selectText again on an active field ends and restarts editing,
        // allowing SwiftUI's blur handler to replace the address and selection.
        // Keep the existing field editor (and any unsubmitted text) instead.
        if let editor = field.currentEditor() as? NSTextView {
          editor.selectAll(nil)
        } else {
          prepareEditing()
          field.selectText(nil)
          field.currentEditor()?.selectAll(nil)
        }
        previousInput = ""
      }

      func prepareEditing() {
        owner.editing = true
        owner.text = owner.fullAddress
        field?.stringValue = owner.fullAddress
        field?.alignment = .left
        if let editor = field?.currentEditor() as? NSTextView {
          editor.setSelectedRange(NSRange(location: 0, length: (owner.fullAddress as NSString).length))
        }
        previousInput = ""
      }
      public func controlTextDidEndEditing(_ notification: Notification) {
        // A suggestion click is delivered before the field loses focus because
        // the panel is nonactivating. Ordinary page clicks dismiss immediately.
        owner.editing = false
        owner.suggestions.dismiss()
        closePanel()
      }
      public func controlTextDidChange(_ notification: Notification) {
        guard let field, let editor = field.currentEditor() as? NSTextView else { return }
        let input = field.stringValue
        owner.text = input
        guard !editor.hasMarkedText() else { owner.suggestions.dismiss(); closePanel(); return }
        owner.suggestions.update(input)
        if input.count > previousInput.count, editor.selectedRange().location == (input as NSString).length,
          let completion = owner.suggestions.inlineCompletion
        {
          field.stringValue = completion
          owner.text = completion
          editor.setSelectedRange(
            NSRange(
              location: (input as NSString).length, length: (completion as NSString).length - (input as NSString).length
            ))
        }
        previousInput = input
        updatePanel()
      }
      public func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
        guard !textView.hasMarkedText() else { return false }
        switch command {
        case #selector(NSResponder.moveDown(_:)):
          owner.suggestions.moveSelection(1); updatePanel(); return true
        case #selector(NSResponder.moveUp(_:)):
          owner.suggestions.moveSelection(-1); updatePanel(); return true
        case #selector(NSResponder.insertNewline(_:)):
          choose(owner.suggestions.selected?.value ?? owner.text); return true
        case #selector(NSResponder.cancelOperation(_:)):
          owner.suggestions.dismiss(); closePanel(); owner.cancel(); return true
        default: return false
        }
      }
      private func choose(_ value: String) {
        owner.suggestions.dismiss()
        closePanel()
        owner.submit(value)
      }
      func updatePanel() {
        guard owner.editing, !owner.suggestions.items.isEmpty, let field, let window = field.window else {
          closePanel(); return
        }
        let popup =
          panel
          ?? NSPanel(
            contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        popup.isReleasedWhenClosed = false
        popup.hidesOnDeactivate = true
        popup.isOpaque = false
        popup.backgroundColor = .clear
        popup.hasShadow = true
        popup.contentView = NSHostingView(
          rootView:
            BrowserSuggestionList(suggestions: owner.suggestions) { [weak self] item in self?.choose(item.value) }
            .background(.regularMaterial, in: .rect(cornerRadius: 18))
        )
        let anchor = window.convertToScreen(field.convert(field.bounds, to: nil))
        let available = anchor.minY - (window.screen?.visibleFrame.minY ?? 0) - 12
        let contentHeight =
          owner.suggestions.items.reduce(16.0) { $0 + ($1.kind == .page ? 62 : 40) }
          + (owner.suggestions.items.contains { $0.kind == .search } ? 36 : 0)
        let height = min(contentHeight, 440, max(100, available))
        popup.setFrame(
          NSRect(x: anchor.minX - 14, y: anchor.minY - height - 14, width: max(280, anchor.width + 48), height: height),
          display: true)
        if panel == nil { window.addChildWindow(popup, ordered: .above); panel = popup }
        popup.orderFront(nil)
      }
      func closePanel() {
        guard let panel else { return }
        panel.parent?.removeChildWindow(panel)
        panel.close()
        self.panel = nil
      }
    }
  }

  private final class AddressField: NSTextField {
    var onFocus: (() -> Void)?
    override func becomeFirstResponder() -> Bool {
      if currentEditor() == nil { onFocus?() }
      return super.becomeFirstResponder()
    }
    override func mouseDown(with event: NSEvent) {
      if currentEditor() == nil {
        onFocus?()
        selectText(nil)
      } else {
        super.mouseDown(with: event)
      }
    }
  }

#endif
