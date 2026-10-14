import CodeHighlighter
import CodevisorTheming
import Foundation
#if canImport(AppKit)
  import AppKit
#elseif canImport(UIKit)
  import UIKit
#endif

enum PlainOutputSyntax {
  static func apply(_ lines: [[CodeHighlighter.Token]], to storage: NSMutableAttributedString) {
    let text = storage.string as NSString
    var lineStart = 0
    for line in lines {
      var offset = lineStart
      for token in line {
        let length = (token.content as NSString).length
        guard offset + length <= text.length else { return }
        if let css = token.color, let rgba = RGBA(css: css) {
          storage.addAttribute(.foregroundColor, value: color(rgba), range: NSRange(location: offset, length: length))
        }
        offset += length
      }
      let rest = NSRange(location: lineStart, length: text.length - lineStart)
      let newline = text.range(of: "\n", options: [], range: rest)
      guard newline.location != NSNotFound else { return }
      lineStart = newline.location + 1
    }
  }

  #if canImport(AppKit)
    private static func color(_ rgba: RGBA) -> NSColor { NSColor(rgba: rgba) }
  #elseif canImport(UIKit)
    private static func color(_ rgba: RGBA) -> UIColor {
      UIColor(red: rgba.r / 255, green: rgba.g / 255, blue: rgba.b / 255, alpha: rgba.a)
    }
  #endif
}
