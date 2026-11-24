import Foundation

#if canImport(AppKit)
  import AppKit
  typealias MarkdownLinkHostView = NSTextView
#elseif canImport(UIKit)
  import UIKit
  typealias MarkdownLinkHostView = UITextView
#endif

@MainActor
enum MarkdownLinkActivation {
  static func activate(
    _ url: URL, with action: MarkdownLinkAction, in textView: MarkdownLinkHostView, at index: Int
  )
    -> Bool
  {
    action.activate(url, isImage: hasImage(in: textView, at: index))
  }

  static func hasImage(in textView: MarkdownLinkHostView, at index: Int) -> Bool {
    #if canImport(AppKit)
      textView.textStorage?.streamMarkdownHasImage(at: index) ?? false
    #else
      textView.textStorage.streamMarkdownHasImage(at: index)
    #endif
  }
}
