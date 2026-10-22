#if canImport(AppKit)
  import AppKit
  import Synchronization

  @MainActor
  final class TextStorageLinkScan: NSObject {
    private static let linkKeys: [NSAttributedString.Key] = [.link, .streamMarkdownServerFileLink]

    private weak var storage: NSTextStorage?
    private let needsRescan = Mutex(true)
    private var foundLinks = false

    func containsLinks(in storage: NSTextStorage) -> Bool {
      if self.storage !== storage { observe(storage) }
      if needsRescan.withLock({ $0 }) { rescan(storage) }
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
      needsRescan.withLock { $0 = true }
    }

    @objc nonisolated private func storageDidEdit(_: Notification) {
      needsRescan.withLock { $0 = true }
    }

    private func rescan(_ storage: NSTextStorage) {
      needsRescan.withLock { $0 = false }
      foundLinks = Self.linkKeys.contains { Self.storage(storage, contains: $0) }
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
