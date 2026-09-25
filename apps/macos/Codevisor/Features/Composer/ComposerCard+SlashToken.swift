import Foundation

extension ComposerCard {
  /// The "/token" being typed at the caret — anywhere in the message, not
  /// just at its start: the nearest "/" before the caret with no whitespace
  /// in between, itself preceded by whitespace or the start of the text
  /// (so paths and URLs like "src/foo" never trigger the palette).
  static func slashTokenRange(in text: String, selection: NSRange) -> NSRange? {
    guard selection.length == 0 else { return nil }
    let text = text as NSString
    let caret = min(selection.location, text.length)
    var index = caret
    while index > 0 {
      let unit = text.character(at: index - 1)
      if isWhitespace(unit) { return nil }
      if unit == unichar(UInt8(ascii: "/")) {
        let slashIndex = index - 1
        guard slashIndex == 0 || isWhitespace(text.character(at: slashIndex - 1)) else {
          return nil
        }
        return NSRange(location: slashIndex, length: caret - slashIndex)
      }
      index -= 1
    }
    return nil
  }

  fileprivate static func isWhitespace(_ unit: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
  }
}
