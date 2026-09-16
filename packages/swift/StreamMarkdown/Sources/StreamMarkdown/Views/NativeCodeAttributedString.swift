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
      var traits: NSFontTraitMask = []
      if run.inlinePresentationIntent?.contains(.stronglyEmphasized) == true { traits.insert(.boldFontMask) }
      if run.inlinePresentationIntent?.contains(.emphasized) == true { traits.insert(.italicFontMask) }
      let styledFont = traits.isEmpty ? font : NSFontManager.shared.convert(font, toHaveTrait: traits)
      result.append(
        NSAttributedString(
          string: String(text[run.range].characters),
          attributes: [
            .font: styledFont,
            .foregroundColor: run.foregroundColor.map(NSColor.init) ?? foreground,
          ]
        )
      )
    }
    return result
  }
#endif
