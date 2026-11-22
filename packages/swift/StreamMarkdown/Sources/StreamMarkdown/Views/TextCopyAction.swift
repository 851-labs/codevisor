import SwiftUI

public struct TextCopyAction {
  public let copy: @MainActor (NSAttributedString) -> Bool

  public init(copy: @escaping @MainActor (NSAttributedString) -> Bool) {
    self.copy = copy
  }
}

extension EnvironmentValues {
  @Entry public var textCopyAction: TextCopyAction? = nil
}

extension NSAttributedString.Key {
  public static let streamMarkdownPlainText = NSAttributedString.Key("streamMarkdown.plainText")
}

extension NSAttributedString {
  public var streamMarkdownPlainText: String {
    let result = NSMutableString(string: string)
    enumerateAttribute(.streamMarkdownPlainText, in: NSRange(location: 0, length: length), options: .reverse) {
      value, range, _ in
      if let text = value as? String { result.replaceCharacters(in: range, with: text) }
    }
    return result as String
  }
}
