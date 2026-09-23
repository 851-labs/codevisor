import CoreText
import UIKit

/// The terminal's fonts, matching Ghostty's embedded default on macOS:
/// JetBrains Mono, falling back to the bundled Nerd Fonts symbols for the
/// Powerline separators and icons that shell prompts (agnoster,
/// Powerlevel10k, Starship) and TUIs draw. The system monospaced face can't
/// be used here: CoreText ignores a cascade list on system UI fonts, so those
/// cells would render as missing-glyph boxes.
enum TerminalFont {
  static let size: CGFloat = 12

  struct Set {
    let normal: UIFont
    let bold: UIFont
    let italic: UIFont
    let boldItalic: UIFont
  }

  private static let bundledFonts = [
    "JetBrainsMono-Regular", "JetBrainsMono-Bold", "JetBrainsMono-Italic",
    "JetBrainsMono-BoldItalic", "SymbolsNerdFontMono-Regular",
  ]

  private static let register: Void = {
    let urls = bundledFonts.compactMap { Bundle.main.url(forResource: $0, withExtension: "ttf") }
    CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
  }()

  static func make() -> Set {
    _ = register
    let symbols = UIFontDescriptor(name: "SymbolsNFM", size: size)
    func font(_ name: String) -> UIFont {
      let descriptor = UIFontDescriptor(fontAttributes: [.name: name, .cascadeList: [symbols]])
      return UIFont(descriptor: descriptor, size: size)
    }
    return Set(
      normal: font("JetBrainsMono-Regular"), bold: font("JetBrainsMono-Bold"),
      italic: font("JetBrainsMono-Italic"), boldItalic: font("JetBrainsMono-BoldItalic"))
  }
}
