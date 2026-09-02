#if canImport(AppKit)
  import AppKit
  import SwiftUI

  func nativeCodeAttributedString(
    _ text: AttributedString,
    foreground: NSColor
  ) -> NSAttributedString {
    let result = NSMutableAttributedString()
    let font = NSFont.monospacedSystemFont(
      ofSize: NSFont.preferredFont(forTextStyle: .callout).pointSize,
      weight: .regular
    )
    for run in text.runs {
      result.append(
        NSAttributedString(
          string: String(text[run.range].characters),
          attributes: [
            .font: font,
            .foregroundColor: run.foregroundColor.map(NSColor.init) ?? foreground,
          ]
        )
      )
    }
    return result
  }
#endif
