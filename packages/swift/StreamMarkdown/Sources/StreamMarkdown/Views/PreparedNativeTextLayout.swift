#if canImport(AppKit) || canImport(UIKit)
  import Foundation
  #if canImport(AppKit)
    import AppKit
  #else
    import UIKit
  #endif

  final class PreparedNativeTextLayout: @unchecked Sendable {
    let text: NSAttributedString
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let container: NSTextContainer
    let size: CGSize

    convenience init(text: NSAttributedString, width: CGFloat, wrapsText: Bool = true, isTable: Bool = false) throws {
      try Task.checkCancellation()
      self.init(laying: text, width: width, wrapsText: wrapsText, isTable: isTable)
      try Task.checkCancellation()
    }

    init(laying text: NSAttributedString, width: CGFloat, wrapsText: Bool = true, isTable: Bool = false) {
      self.text = text
      storage = NSTextStorage(attributedString: text)
      #if canImport(AppKit)
        manager = StreamingTextLayoutManager()
        manager.backgroundLayoutEnabled = false
        if isTable { MarkdownTableTypesetter.install(on: manager) }
      #else
        manager = UIKitStreamingTextLayoutManager()
      #endif
      container = NSTextContainer(size: CGSize(width: width, height: .greatestFiniteMagnitude))
      container.lineFragmentPadding = 0
      container.widthTracksTextView = false
      container.heightTracksTextView = false
      storage.addLayoutManager(manager)
      manager.addTextContainer(container)
      manager.ensureLayout(for: container)
      let used = manager.usedRect(for: container)
      size = CGSize(width: wrapsText ? width : max(1, ceil(used.width)), height: max(1, ceil(used.height)))
    }

    #if canImport(AppKit)
      @MainActor
      func updateForegroundColors(from text: NSAttributedString) {
        let range = NSRange(location: 0, length: storage.length)
        manager.removeTemporaryAttribute(.foregroundColor, forCharacterRange: range)
        text.enumerateAttribute(.foregroundColor, in: range) { color, range, _ in
          if let color { manager.addTemporaryAttribute(.foregroundColor, value: color, forCharacterRange: range) }
        }
        manager.invalidateDisplay(forCharacterRange: range)
      }
    #endif
  }
#endif
