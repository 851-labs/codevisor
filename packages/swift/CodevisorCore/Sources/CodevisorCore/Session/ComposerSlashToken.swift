import Foundation

/// The "/token" or "$token" being typed at the composer's caret. Shared by
/// the macOS and iOS palettes so both open on exactly the same text.
public struct ComposerSlashToken: Equatable, Sendable {
  public enum Trigger: Character, Sendable {
    case slash = "/"
    /// Codex invokes skills with "$"; people used to it type that instead.
    case dollar = "$"
  }

  /// The trigger character through the caret, in UTF-16 offsets (the
  /// coordinate space of NSTextView and UITextView selections).
  public let range: NSRange
  public let trigger: Trigger
  /// The text after the trigger, lowercased for matching.
  public let query: String

  /// The token at a collapsed caret, anywhere in the message: the nearest
  /// trigger before the caret with no whitespace in between, itself preceded
  /// by whitespace or the start of the text. Paths, URLs, and prices
  /// ("src/foo", "$HOME/x", "US$5") therefore never open the palette.
  public init?(in text: String, selection: NSRange) {
    guard selection.length == 0 else { return nil }
    let text = text as NSString
    let caret = min(selection.location, text.length)
    var index = caret
    while index > 0 {
      let unit = text.character(at: index - 1)
      if Self.isWhitespace(unit) { return nil }
      if let trigger = Self.trigger(for: unit) {
        let triggerIndex = index - 1
        guard triggerIndex == 0 || Self.isWhitespace(text.character(at: triggerIndex - 1)) else {
          return nil
        }
        range = NSRange(location: triggerIndex, length: caret - triggerIndex)
        self.trigger = trigger
        query = text.substring(with: NSRange(location: index, length: caret - index)).lowercased()
        return
      }
      index -= 1
    }
    return nil
  }

  private static func trigger(for unit: unichar) -> Trigger? {
    guard let scalar = Unicode.Scalar(unit) else { return nil }
    return Trigger(rawValue: Character(scalar))
  }

  private static func isWhitespace(_ unit: unichar) -> Bool {
    guard let scalar = Unicode.Scalar(unit) else { return false }
    return CharacterSet.whitespacesAndNewlines.contains(scalar)
  }
}
