import Foundation
import SwiftUI

#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

struct MarkdownImageReference: Hashable, Sendable {
  let source: String
  let alt: String
}

struct MarkdownImageReferenceAttribute: AttributedStringKey {
  typealias Value = MarkdownImageReference
  static let name = "streamMarkdown.imageReference"
}

/// Table preparation owns immutable attachments. Resizing always makes a new
/// attachment, leaving cached layouts for other widths untouched.
extension NSAttributedString.Key {
  static let streamMarkdownImageAlt = NSAttributedString.Key("streamMarkdown.imageAlt")
}

extension NSAttributedString {
  /// Whether the character at `index` is an image the renderer drew inline
  /// (its attachment carries the alt text used for copying and
  /// accessibility). Unloaded images render as text and count as links.
  func streamMarkdownHasImage(at index: Int) -> Bool {
    guard index >= 0, index < length else { return false }
    return attribute(.streamMarkdownImageAlt, at: index, effectiveRange: nil) != nil
  }
}

enum MarkdownImageAttachment {
  static func content(
    _ reference: MarkdownImageReference,
    resource: MarkdownImageResource?,
    attributes: [NSAttributedString.Key: Any]
  ) -> NSAttributedString {
    guard case let .loaded(image) = resource else {
      let label = reference.alt.isEmpty ? "Image" : reference.alt
      let text = resource == .unavailable ? "[\(label) unavailable]" : "[\(label)…]"
      return NSAttributedString(string: text, attributes: attributes)
    }
    let size = fittedSize(image.image.size, width: 320)
    let attachment = make(image: image.image, size: size)
    let result = NSMutableAttributedString(attachment: attachment)
    result.addAttributes(attributes, range: NSRange(location: 0, length: result.length))
    result.addAttribute(
      .streamMarkdownImageAlt, value: reference.alt.isEmpty ? "Image" : reference.alt,
      range: NSRange(location: 0, length: result.length))
    return result
  }

  static func fittedSize(_ size: CGSize, width: CGFloat) -> CGSize {
    guard size.width > 0, size.height > 0, size.width.isFinite, size.height.isFinite else {
      return CGSize(width: 1, height: 1)
    }
    let scale = min(1, min(max(1, width), 320) / size.width, 360 / size.height)
    return CGSize(width: size.width * scale, height: size.height * scale)
  }

  static func fitting(_ text: NSAttributedString, width: CGFloat) -> NSAttributedString {
    let result = NSMutableAttributedString(attributedString: text)
    text.enumerateAttribute(.attachment, in: NSRange(location: 0, length: text.length)) { value, range, _ in
      guard let attachment = value as? NSTextAttachment, let image = attachment.image else { return }
      result.addAttribute(
        .attachment, value: make(image: image, size: fittedSize(image.size, width: width)), range: range)
    }
    return result
  }

  static func plainText(_ text: NSAttributedString) -> String {
    let result = NSMutableString(string: text.string)
    text.enumerateAttribute(.streamMarkdownImageAlt, in: NSRange(location: 0, length: text.length), options: .reverse) {
      value, range, _ in
      if let alt = value as? String { result.replaceCharacters(in: range, with: alt) }
    }
    return result as String
  }

  static func minimumWidth(of fragment: NSAttributedString) -> CGFloat {
    let fitted = fitting(fragment, width: 100)
    return fitted.size().width
  }

  private static func make(image: MarkdownPlatformImage, size: CGSize) -> NSTextAttachment {
    let attachment = NSTextAttachment()
    attachment.image = image
    attachment.bounds = CGRect(origin: .zero, size: size)
    #if canImport(AppKit)
      let resized = NSImage(size: size, flipped: false) { rect in
        image.draw(in: rect)
        return true
      }
      attachment.image = resized
    #endif
    return attachment
  }
}
