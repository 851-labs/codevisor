#if canImport(UIKit)
  import CodeHighlighter
  import CodevisorTheming
  import SwiftUI
  import UIKit

  typealias NativeFileEditor = IOSFileEditor
  typealias FileTextView = FileSourceTextView
  typealias FileColor = UIColor
  extension UIColor { static var fileEditorLabel: UIColor { .label } }

  @MainActor
  final class IOSFileEditor {
    let textView: FileSourceTextView
    private let gutter = FileLineGutter()

    init() {
      let storage = NSTextStorage()
      let layout = NSLayoutManager()
      let textContainer = NSTextContainer(size: .zero)
      storage.addLayoutManager(layout)
      layout.addTextContainer(textContainer)
      textView = FileSourceTextView(frame: .zero, textContainer: textContainer)
      textView.autocorrectionType = .no
      textView.autocapitalizationType = .none
      textView.spellCheckingType = .no
      textView.smartQuotesType = .no
      textView.smartDashesType = .no
      textView.smartInsertDeleteType = .no
      textView.font = UIFontMetrics(forTextStyle: .body).scaledFont(
        for: .monospacedSystemFont(ofSize: 13, weight: .regular))
      textView.adjustsFontForContentSizeCategory = true
      textView.textContainerInset = UIEdgeInsets(top: 18, left: 48, bottom: 24, right: 16)
      textView.accessibilityLabel = "File editor"
      textView.keyboardDismissMode = .interactive
      textView.contentInsetAdjustmentBehavior = .always
      // Keep the insertion point clear of the keyboard when UIKit reveals it.
      textView.contentInset.bottom = 24
      textView.alwaysBounceVertical = true
      gutter.textView = textView
      gutter.isUserInteractionEnabled = false
      gutter.backgroundColor = .clear
      textView.addSubview(gutter)
    }

    var text: String {
      get { textView.text ?? "" }
      set { textView.text = newValue }
    }
    var selection: NSRange { textView.selectedRange }
    func connect(_ storage: FileEditorStorage) { textView.delegate = storage }

    func update(theme: Theme, session: FileEditorSession) {
      textView.isEditable = session.document.isEditable
      textView.backgroundColor = UIColor(theme.windowBackground)
      gutter.isHidden = !session.showsLineNumbers
      textView.textContainerInset.left = session.showsLineNumbers ? 48 : 16
      // Touch editing wraps; selection and Go to Line navigate compact displays.
    }

    func revealSelection(_ range: NSRange) {
      textView.selectedRange = range
      textView.pendingSelection = range
      textView.setNeedsLayout()
    }
    func replace(range: NSRange, with replacement: String) {
      if let start = textView.position(from: textView.beginningOfDocument, offset: range.location),
        let end = textView.position(from: start, offset: range.length),
        let target = textView.textRange(from: start, to: end)
      {
        textView.replace(target, withText: replacement)
      }
    }
    func resignFocus() { textView.resignFirstResponder() }
    func redrawGutter() {
      gutter.frame = CGRect(x: 0, y: 0, width: 44, height: max(textView.bounds.height, textView.contentSize.height))
      gutter.setNeedsDisplay()
    }
  }

  extension FileEditorStorage: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) { changed() }
    func textViewDidChangeSelection(_ textView: UITextView) { selectionChanged() }
    func scrollViewDidScroll(_ scrollView: UIScrollView) { native.redrawGutter() }
  }

  struct NativeFileSourceEditor: UIViewRepresentable {
    let storage: FileEditorStorage
    let theme: Theme
    let highlight: CodeHighlightTheme?
    func makeUIView(context: Context) -> UITextView { storage.native.textView }
    func updateUIView(_ view: UITextView, context: Context) { storage.update(theme: theme, highlight: highlight) }
    func sizeThatFits(_ proposal: ProposedViewSize, uiView: UITextView, context: Context) -> CGSize? {
      CGSize(width: proposal.width ?? 400, height: proposal.height ?? 400)
    }
  }
#endif
