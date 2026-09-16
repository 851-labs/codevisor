import SwiftUI

#if canImport(AppKit)
  import AppKit

  final class FileSourceTextView: NSTextView {
    override func insertNewline(_ sender: Any?) {
      let source = string as NSString
      let line = source.lineRange(for: NSRange(location: selectedRange().location, length: 0))
      let prefix = source.substring(
        with: NSRange(location: line.location, length: selectedRange().location - line.location))
      let indentation = prefix.prefix { $0 == " " || $0 == "\t" }
      insertText("\n" + indentation, replacementRange: selectedRange())
    }

    override func insertTab(_ sender: Any?) {
      if selectedRange().length == 0 { insertText("  ", replacementRange: selectedRange()); return }
      indent(unindent: false)
    }

    override func insertBacktab(_ sender: Any?) { indent(unindent: true) }

    private func indent(unindent: Bool) {
      let source = string as NSString
      let range = source.lineRange(for: selectedRange())
      let lines = source.substring(with: range).components(separatedBy: "\n")
      let replacement = lines.enumerated().map { index, line in
        if index == lines.count - 1 && line.isEmpty { return line }
        if !unindent { return "  " + line }
        if line.hasPrefix("\t") { return String(line.dropFirst()) }
        return String(line.dropFirst(line.prefix(2).prefix(while: { $0 == " " }).count))
      }.joined(separator: "\n")
      insertText(replacement, replacementRange: range)
      setSelectedRange(NSRange(location: range.location, length: (replacement as NSString).length))
    }
  }

#else
  import UIKit

  final class FileSourceTextView: UITextView {
    var pendingSelection: NSRange?

    override func layoutSubviews() {
      super.layoutSubviews()
      // Navigation bars contribute to the adjusted insets only after layout.
      // Revealing the selection earlier can put the first line behind the bar.
      if let range = pendingSelection, window != nil, bounds.width > 0, bounds.height > 0 {
        pendingSelection = nil
        scrollRangeToVisible(range)
      }
    }
  }

  final class FileLineGutter: UIView {
    weak var textView: UITextView?
    override func draw(_ rect: CGRect) {
      guard let textView else { return }
      let layout = textView.layoutManager
      let source = (textView.text ?? "") as NSString
      let visible = CGRect(origin: textView.contentOffset, size: textView.bounds.size)
      let glyphs = layout.glyphRange(forBoundingRect: visible.offsetBy(dx: -48, dy: -18), in: textView.textContainer)
      let start =
        layout.numberOfGlyphs == 0
        ? 0 : min(source.length, layout.characterIndexForGlyph(at: min(glyphs.location, layout.numberOfGlyphs - 1)))
      var lineNumber = source.substring(to: start).reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
      var previousCharacter = start
      let attributes: [NSAttributedString.Key: Any] = [
        .font: UIFont.monospacedDigitSystemFont(ofSize: 11, weight: .regular), .foregroundColor: UIColor.secondaryLabel,
      ]
      layout.enumerateLineFragments(forGlyphRange: glyphs) { fragment, _, _, range, _ in
        let character = layout.characterIndexForGlyph(at: range.location)
        lineNumber +=
          source.substring(with: NSRange(location: previousCharacter, length: max(0, character - previousCharacter)))
          .filter { $0 == "\n" }.count
        previousCharacter = character
        guard character == 0 || source.character(at: character - 1) == 10 else { return }
        let label = "\(lineNumber)" as NSString
        let size = label.size(withAttributes: attributes)
        label.draw(at: CGPoint(x: 34 - size.width, y: fragment.minY + 18 + 1), withAttributes: attributes)
      }
      if source.length == 0 { ("1" as NSString).draw(at: CGPoint(x: 27, y: 19), withAttributes: attributes) }
    }
  }
#endif
