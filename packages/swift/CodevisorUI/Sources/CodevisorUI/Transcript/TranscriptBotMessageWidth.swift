import SwiftUI

#if canImport(UIKit)
  import UIKit

  private typealias MessageFont = UIFont
#else
  import AppKit

  private typealias MessageFont = NSFont
#endif

public enum TranscriptBotMessageWidth {
  public static func natural(of markdown: String) -> CGFloat {
    let body = MessageFont.preferredFont(forTextStyle: .body)
    let code = MessageFont.monospacedSystemFont(ofSize: body.pointSize * 0.9, weight: .regular)
    var inFence = false
    var widest: CGFloat = 0
    for line in markdown.split(separator: "\n", omittingEmptySubsequences: false) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("```") {
        inFence.toggle()
        continue
      }
      let font = inFence ? code : body
      let indent: CGFloat =
        !inFence && trimmed.range(of: #"^([-*+]|\d+[.)])\s"#, options: .regularExpression) != nil ? 24 : 0
      let width = (String(line) as NSString).size(withAttributes: [.font: font]).width
      let codeSpans = inFence ? 0 : CGFloat(line.filter { $0 == "`" }.count / 2)
      widest = max(widest, ceil(width + indent + codeSpans * 14 + (inFence ? 24 : 4)))
    }
    return max(widest, 1)
  }
}
