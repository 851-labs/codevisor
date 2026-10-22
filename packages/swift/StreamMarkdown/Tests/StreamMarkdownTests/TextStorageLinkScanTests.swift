#if canImport(AppKit)
  import AppKit
  import Testing

  @testable import StreamMarkdown

  @MainActor
  @Suite("Text storage link scan")
  struct TextStorageLinkScanTests {
    private struct UncheckedStorage: @unchecked Sendable {
      let storage: NSTextStorage
    }

    @Test("An edit notification posted off the main thread marks the scan stale")
    func offMainEditNotificationMarksScanStale() async {
      let scan = TextStorageLinkScan()
      let storage = NSTextStorage(string: "plain text")
      #expect(!scan.containsLinks(in: storage))

      storage.beginEditing()
      storage.addAttribute(.link, value: "https://example.com", range: NSRange(location: 0, length: 5))
      let box = UncheckedStorage(storage: storage)
      await Task.detached {
        NotificationCenter.default.post(name: NSTextStorage.didProcessEditingNotification, object: box.storage)
      }.value

      #expect(scan.containsLinks(in: storage))
      storage.endEditing()
    }
  }
#endif
