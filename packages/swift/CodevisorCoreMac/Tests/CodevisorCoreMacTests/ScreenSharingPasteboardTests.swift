import AppKit
import ScreenSharing
import Testing
@testable import CodevisorCoreMac

@MainActor
struct ScreenSharingPasteboardTests {
  @Test func aNewerLocalCopyIsNotOverwrittenByAnInFlightDownload() throws {
    let pasteboard = NSPasteboard(name: .init("screen-sharing-test-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    let adapter = ScreenSharingPasteboard(pasteboard)
    try adapter.write(.init(text: "original"))
    let expected = adapter.changeCount
    try adapter.write(.init(text: "newer local copy"))
    #expect(throws: (any Error).self) {
      try adapter.write(.init(text: "late remote copy"), expectedChangeCount: expected)
    }
    #expect(try adapter.readText() == "newer local copy")
    try adapter.write(.init(text: "remote ✓"), expectedChangeCount: adapter.changeCount)
    #expect(try adapter.readText() == "remote ✓")
  }

  @Test func unsupportedAndOversizedContentsDoNotBecomeTextTransfers() throws {
    let pasteboard = NSPasteboard(name: .init("screen-sharing-test-\(UUID())"))
    defer { pasteboard.releaseGlobally() }
    let adapter = ScreenSharingPasteboard(pasteboard)
    pasteboard.setData(Data([1, 2, 3]), forType: .png)
    #expect(throws: (any Error).self) { try adapter.read(richContent: false) }
    pasteboard.clearContents()
    pasteboard.setString(String(repeating: "a", count: 65537), forType: .string)
    #expect(throws: (any Error).self) { try adapter.read(richContent: false) }
  }

  @Test func everyItemAndTypeCrossesToAnotherPasteboardExceptReferencesToLocalFiles() throws {
    let source = NSPasteboard(name: .init("screen-sharing-test-\(UUID())"))
    let destination = NSPasteboard(name: .init("screen-sharing-test-\(UUID())"))
    defer {
      source.releaseGlobally()
      destination.releaseGlobally()
    }
    let png = Data([0x89, 0x50, 0x4E, 0x47, 1, 2, 3])
    let image = NSPasteboardItem()
    image.setData(png, forType: .png)
    image.setString("screenshot", forType: .string)
    image.setString("file:///Users/someone/screenshot.png", forType: .fileURL)
    let styled = NSPasteboardItem()
    styled.setData(Data("{\\rtf1 b}".utf8), forType: .rtf)
    styled.setData(Data([9, 9]), forType: .init("com.example.private-clip"))
    source.clearContents()
    source.writeObjects([image, styled])

    let content = try ScreenSharingPasteboard(source).read(richContent: true)
    #expect(content.items.flatMap { $0 }.allSatisfy { $0.type != NSPasteboard.PasteboardType.fileURL.rawValue })
    try ScreenSharingPasteboard(destination).write(content)

    let items = try #require(destination.pasteboardItems)
    #expect(items.count == 2)
    #expect(items[0].data(forType: .png) == png)
    #expect(items[0].string(forType: .string) == "screenshot")
    #expect(items[0].types.contains(.fileURL) == false)
    #expect(items[1].data(forType: .rtf) == Data("{\\rtf1 b}".utf8))
    #expect(items[1].data(forType: .init("com.example.private-clip")) == Data([9, 9]))
  }
}
