#if canImport(AppKit)
  import AppKit

  enum MarkdownTableAccessibility {
    static func attributedText(_ source: NSAttributedString, in range: NSRange) -> NSAttributedString? {
      guard range.location >= 0, range.length >= 0, range.location <= source.length,
        range.length <= source.length - range.location
      else { return nil }
      let result = NSMutableAttributedString(string: (source.string as NSString).substring(with: range))
      source.enumerateAttributes(in: range) { attributes, sourceRange, _ in
        var output: [NSAttributedString.Key: Any] = [:]
        if let font = attributes[.font] as? NSFont {
          output[.accessibilityFont] = [
            NSAccessibility.FontAttributeKey.fontName: font.fontName,
            .fontSize: font.pointSize,
          ]
        }
        if let color = attributes[.foregroundColor] as? NSColor {
          output[.accessibilityForegroundColor] = color.cgColor
        }
        if let color = attributes[.backgroundColor] as? NSColor {
          output[.accessibilityBackgroundColor] = color.cgColor
        }
        if let style = attributes[.underlineStyle] { output[.accessibilityUnderline] = style }
        if let style = attributes[.strikethroughStyle] as? Int {
          output[.accessibilityStrikethrough] = style != 0
        }
        result.setAttributes(
          output, range: NSRange(location: sourceRange.location - range.location, length: sourceRange.length))
      }
      return result
    }
  }
#endif
