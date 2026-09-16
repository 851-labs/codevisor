#if canImport(AppKit)
  import AppKit
  import CodeHighlighter
  import CodevisorTheming
  import SwiftUI

  typealias NativeFileEditor = MacFileEditor
  typealias FileTextView = FileSourceTextView
  typealias FileColor = NSColor
  extension NSColor { static var fileEditorLabel: NSColor { .labelColor } }

  @MainActor
  final class MacFileEditor {
    let textView = FileSourceTextView(frame: NSRect(x: 0, y: 0, width: 700, height: 400))
    let container = FileEditorScrollView()

    init() {
      textView.isRichText = false
      textView.allowsUndo = true
      textView.isAutomaticQuoteSubstitutionEnabled = false
      textView.isAutomaticDashSubstitutionEnabled = false
      textView.isAutomaticTextReplacementEnabled = false
      textView.isAutomaticSpellingCorrectionEnabled = false
      textView.isContinuousSpellCheckingEnabled = false
      textView.isGrammarCheckingEnabled = false
      textView.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
      textView.textContainerInset = NSSize(width: 14, height: 16)
      textView.isVerticallyResizable = true
      textView.autoresizingMask = [.width]
      textView.minSize = .zero
      textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      textView.setAccessibilityLabel("File editor")
      container.hasVerticalScroller = true
      container.hasHorizontalScroller = true
      container.autohidesScrollers = true
      container.borderType = .noBorder
      container.automaticallyAdjustsContentInsets = false
      container.documentView = textView
      container.gutter.textView = textView
      // AppKit scrolls this with the document vertically and pins it horizontally.
      container.addFloatingSubview(container.gutter, for: .horizontal)
    }

    var text: String {
      get { textView.string }
      set { textView.string = newValue }
    }
    var selection: NSRange { textView.selectedRange() }
    func connect(_ storage: FileEditorStorage) { textView.delegate = storage }

    func update(theme: Theme, session: FileEditorSession) {
      textView.isEditable = session.document.isEditable
      container.gutter.isHidden = !session.showsLineNumbers
      container.gutter.update()
      // System themes composite the text onto the window's live backdrop,
      // like the terminal surface; custom palettes paint their own color.
      let paintsBackground = !theme.isSystem
      textView.drawsBackground = paintsBackground
      container.drawsBackground = paintsBackground
      textView.backgroundColor = paintsBackground ? NSColor(theme.windowBackground) : .clear
      container.backgroundColor = textView.backgroundColor
      textView.insertionPointColor = NSColor(theme.textPrimary)
      let wraps = session.wrapsLines
      textView.isHorizontallyResizable = !wraps
      textView.autoresizingMask = wraps ? [.width] : []
      textView.textContainer?.widthTracksTextView = wraps
      if wraps {
        textView.setFrameSize(NSSize(width: container.contentSize.width, height: textView.frame.height))
        let origin = container.contentView.bounds.origin
        if origin.x != 0 { container.contentView.scroll(to: NSPoint(x: 0, y: origin.y)) }
      }
      textView.textContainer?.containerSize = NSSize(
        width: wraps ? max(1, container.contentSize.width - 2 * textView.textContainerInset.width) : 100_000,
        height: CGFloat.greatestFiniteMagnitude)
    }

    func revealSelection(_ range: NSRange) {
      textView.setSelectedRange(range)
      container.pendingSelection = range
      container.needsLayout = true
    }
    func replace(range: NSRange, with replacement: String) {
      textView.insertText(replacement, replacementRange: range)
    }
    func resignFocus() {
      if textView.window?.firstResponder === textView { textView.window?.makeFirstResponder(nil) }
    }
    func redrawGutter() { container.gutter.update() }
  }

  final class FileEditorScrollView: NSScrollView {
    let gutter = MacFileLineGutter()
    var pendingSelection: NSRange?

    override func reflectScrolledClipView(_ clipView: NSClipView) {
      super.reflectScrolledClipView(clipView)
      // Document height can change after TextKit lays out an edit or wraps lines.
      gutter.setFrameSize(
        NSSize(width: gutter.width, height: max(contentSize.height, documentView?.frame.height ?? 0)))
      gutter.scrolledHorizontally = clipView.bounds.origin.x > 0
    }

    override func layout() {
      super.layout()
      // Reveal the selection after the editor has its final viewport size.
      if let range = pendingSelection, window != nil, contentSize.width > 0,
        let textView = documentView as? NSTextView
      {
        pendingSelection = nil
        textView.scrollRangeToVisible(range)
      }
    }
  }

  extension FileEditorStorage: NSTextViewDelegate {
    func textDidChange(_ notification: Notification) { changed() }
    func textViewDidChangeSelection(_ notification: Notification) { selectionChanged() }
  }

  struct NativeFileSourceEditor: NSViewRepresentable {
    let storage: FileEditorStorage
    let theme: Theme
    let highlight: CodeHighlightTheme?
    func makeNSView(context: Context) -> NSScrollView { storage.native.container }
    func updateNSView(_ view: NSScrollView, context: Context) { storage.update(theme: theme, highlight: highlight) }
    func sizeThatFits(_ proposal: ProposedViewSize, nsView: NSScrollView, context: Context) -> CGSize? {
      CGSize(width: proposal.width ?? 600, height: proposal.height ?? 400)
    }
  }
#endif
