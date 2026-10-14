import Foundation

public struct ComposerSlashToken: Equatable, Sendable {
  public enum Trigger: Character, Sendable {
    case slash = "/"
    case dollar = "$"
  }

  public let range: NSRange
  public let trigger: Trigger
  public let query: String

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
