import SwiftUI

public struct TextQuoteAction {
  public let add: @MainActor (String) -> Void

  public init(add: @escaping @MainActor (String) -> Void) {
    self.add = add
  }
}

extension EnvironmentValues {
  @Entry public var textQuoteAction: TextQuoteAction? = nil
}

#if canImport(UIKit) && !canImport(AppKit)
  import UIKit

  @MainActor
  func textQuoteEditMenu(
    in textView: UITextView, range: NSRange, suggestedActions: [UIMenuElement], action: TextQuoteAction?
  ) -> UIMenu? {
    guard let action, range.length > 0, NSMaxRange(range) <= textView.textStorage.length else { return nil }

    let text = (textView.textStorage.string as NSString).substring(with: range)
    let addToChat = UIAction(title: "Add to Chat", image: UIImage(systemName: "text.quote")) { [weak textView] _ in
      action.add(text)
      textView?.selectedRange = NSRange(location: range.location, length: 0)
    }
    return UIMenu(children: [addToChat] + suggestedActions)
  }
#endif
