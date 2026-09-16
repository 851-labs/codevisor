#if canImport(AppKit)
  import AppKit

  /// Shares the document's vertical coordinates, including elastic scrolling.
  final class MacFileLineGutter: NSView {
    private static let numberFont = NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular)
    private var previousText = ""
    private(set) var width: CGFloat = 32
    weak var textView: NSTextView?
    override var isFlipped: Bool { true }
    override var isOpaque: Bool { textView?.drawsBackground ?? false }
    /// A transparent gutter (system themes) sits over empty inset until the
    /// text scrolls sideways beneath it; only then does it need a backing fill.
    var scrolledHorizontally = false {
      didSet { if scrolledHorizontally != oldValue { needsDisplay = true } }
    }

    // Let the text view handle scrolling and selection over the gutter too.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update() {
      guard let textView else { return }
      if previousText != textView.string {
        previousText = textView.string
        let lines = previousText.utf8.reduce(1) { $1 == 10 ? $0 + 1 : $0 }
        let digits = ("\(lines)" as NSString).size(withAttributes: [.font: Self.numberFont]).width
        width = max(32, ceil(digits) + 12)
      }
      let inset = isHidden ? 14 : width + 8
      if textView.textContainerInset.width != inset { textView.textContainerInset.width = inset }
      setFrameSize(
        NSSize(width: width, height: max(textView.bounds.height, textView.enclosingScrollView?.contentSize.height ?? 0))
      )
      needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
      guard let textView, let layout = textView.layoutManager, let container = textView.textContainer else { return }
      NSBezierPath(rect: bounds).addClip()
      if textView.drawsBackground {
        textView.backgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
      } else if scrolledHorizontally {
        NSColor.windowBackgroundColor.setFill()
        bounds.intersection(dirtyRect).fill()
      }
      let origin = textView.textContainerOrigin
      let glyphs = layout.glyphRange(
        forBoundingRect: NSRect(
          x: 0, y: dirtyRect.minY - origin.y, width: container.size.width, height: dirtyRect.height),
        in: container)
      let source = textView.string as NSString
      let start =
        glyphs.location < layout.numberOfGlyphs ? layout.characterIndexForGlyph(at: glyphs.location) : source.length
      var lineNumber = source.substring(to: start).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
      var previousCharacter = start
      let attributes: [NSAttributedString.Key: Any] = [
        .font: Self.numberFont,
        .foregroundColor: NSColor.secondaryLabelColor,
      ]
      func drawNumber(_ number: Int, at y: CGFloat) {
        let label = "\(number)" as NSString
        label.draw(
          at: NSPoint(x: width - 6 - label.size(withAttributes: attributes).width, y: y + origin.y + 1),
          withAttributes: attributes)
      }
      layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
        let character = layout.characterIndexForGlyph(at: range.location)
        lineNumber +=
          source.substring(with: NSRange(location: previousCharacter, length: character - previousCharacter))
          .filter { $0 == "\n" }.count
        previousCharacter = character
        guard character == 0 || source.character(at: character - 1) == 10 else { return }
        drawNumber(lineNumber, at: fragment.minY)
      }
      let extra = layout.extraLineFragmentRect.offsetBy(dx: 0, dy: origin.y)
      if layout.extraLineFragmentTextContainer === container,
        extra.maxY >= dirtyRect.minY, extra.minY <= dirtyRect.maxY
      {
        drawNumber(
          source.substring(from: previousCharacter).reduce(lineNumber) { $1 == "\n" ? $0 + 1 : $0 },
          at: layout.extraLineFragmentRect.minY)
      }
    }
  }
#endif
