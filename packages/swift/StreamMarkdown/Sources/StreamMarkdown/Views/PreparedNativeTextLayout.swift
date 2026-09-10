#if canImport(AppKit) || canImport(UIKit)
  import Foundation
  #if canImport(AppKit)
    import AppKit
  #else
    import UIKit
  #endif

  /// An exclusively owned TextKit stack prepared without a text view. The
  /// worker finishes all access before handing it to the UI actor. Native
  /// views then draw and select through that same layout, avoiding a second
  /// typesetting pass during mounting.
  final class PreparedNativeTextLayout: @unchecked Sendable {
    let text: NSAttributedString
    let storage: NSTextStorage
    let manager: NSLayoutManager
    let container: NSTextContainer
    let size: CGSize

    init(text: NSAttributedString, width: CGFloat, wrapsText: Bool = true) throws {
      try Task.checkCancellation()
      self.text = text
      storage = NSTextStorage(attributedString: text)
      #if canImport(AppKit)
        manager = StreamingTextLayoutManager()
        manager.backgroundLayoutEnabled = false
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
      try Task.checkCancellation()
      let used = manager.usedRect(for: container)
      size = CGSize(width: wrapsText ? width : max(1, ceil(used.width)), height: max(1, ceil(used.height)))
    }

    #if canImport(AppKit)
      /// AppKit temporary attributes update syntax colors without invalidating
      /// glyph geometry or replacing the native selection owner.
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
