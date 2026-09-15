import AppKit
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingPasteboardTests {
  @Test func aNewerLocalCopyIsNotOverwrittenByAnInFlightDownload() throws {
    let pasteboard = NSPasteboard(name: .init("screen-sharing-test-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    let adapter = ScreenSharingPasteboard(pasteboard)
    try adapter.write("original")
    let expected = adapter.changeCount
    try adapter.write("newer local copy")
    #expect(throws: (any Error).self) { try adapter.write("late remote copy", expectedChangeCount: expected) }
    #expect(try adapter.read() == "newer local copy")
    try adapter.write("remote ✓", expectedChangeCount: adapter.changeCount)
    #expect(try adapter.read() == "remote ✓")
  }

  @Test func unsupportedAndOversizedContentsDoNotBecomeTextTransfers() throws {
    let pasteboard = NSPasteboard(name: .init("screen-sharing-test-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    let adapter = ScreenSharingPasteboard(pasteboard)
    pasteboard.setData(Data([1, 2, 3]), forType: .png)
    #expect(throws: (any Error).self) { try adapter.read() }
    pasteboard.clearContents()
    pasteboard.setString(String(repeating: "a", count: 65537), forType: .string)
    #expect(throws: (any Error).self) { try adapter.read() }
  }
}
