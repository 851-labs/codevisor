#if canImport(AppKit)
  import AppKit

  @MainActor
  final class TextStorageLinkScan: NSObject {
    private static let linkKeys: [NSAttributedString.Key] = [.link, .streamMarkdownServerFileLink]

    private weak var storage: NSTextStorage?
    private var isCurrent = false
    private var foundLinks = false

    func containsLinks(in storage: NSTextStorage) -> Bool {
      if self.storage !== storage { observe(storage) }
      if !isCurrent { rescan(storage) }
      return foundLinks
    }

    private func observe(_ storage: NSTextStorage) {
      let center = NotificationCenter.default
      center.removeObserver(self)
      center.addObserver(
        self,
        selector: #selector(storageDidEdit(_:)),
        name: NSTextStorage.didProcessEditingNotification,
        object: storage
      )
      self.storage = storage
      isCurrent = false
    }

    @objc private func storageDidEdit(_: Notification) {
      isCurrent = false
    }

    private func rescan(_ storage: NSTextStorage) {
      foundLinks = Self.linkKeys.contains { Self.storage(storage, contains: $0) }
      isCurrent = true
    }

    private static func storage(_ storage: NSTextStorage, contains key: NSAttributedString.Key) -> Bool {
      var found = false
      let range = NSRange(location: 0, length: storage.length)
      storage.enumerateAttribute(key, in: range, options: [.longestEffectiveRangeNotRequired]) { value, _, stop in
        guard value != nil else { return }
        found = true
        stop.pointee = true
      }
      return found
    }
  }
#endif
