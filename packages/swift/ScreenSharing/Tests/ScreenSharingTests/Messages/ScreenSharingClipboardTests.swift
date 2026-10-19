import Foundation
import Testing
@testable import ScreenSharing

@MainActor
struct ScreenSharingClipboardTests {
  @Test func explicitRoundTripsPreserveUnicodeAcrossChunkBoundariesAndBoundTheQueue() throws {
    let fixture = ClipboardFixture()
    let value = String(repeating: "é👩🏽‍💻日本語\n", count: 1500)
    fixture.viewer.sendContent(.init(text: value))
    #expect(fixture.viewer.isBusy)
    fixture.drain()
    #expect(fixture.hostText == value)
    #expect(fixture.maximumQueued <= 1)
    #expect(!fixture.viewer.isBusy && !fixture.host.isBusy)
    #expect(fixture.viewerResults.last! == nil)
    fixture.hostText = "Remote clipboard ✓"
    fixture.viewer.requestContent()
    fixture.drain()
    #expect(fixture.viewerText == fixture.hostText)
    #expect(fixture.viewerResults.count == 2)
  }

  @Test func viewerRejectsUnrequestedClipboardAndNeverChangesItsPasteboard() {
    let fixture = ClipboardFixture()
    fixture.host.sendContent(.init(text: "unsolicited"))
    fixture.drain()
    #expect(fixture.viewerText == "local")
    #expect(fixture.hostResults.last! != nil)
    #expect(!fixture.host.isBusy)
  }

  @Test func lateChunksCannotCompleteAfterCancellationOrTimeout() {
    let fixture = ClipboardFixture()
    fixture.viewer.requestContent()
    fixture.deliverOne()
    fixture.deliverOne()
    fixture.viewer.cancel()
    fixture.drain()
    #expect(fixture.viewerText == "local")
    #expect(!fixture.host.isBusy && !fixture.viewer.isBusy)

    fixture.viewer.requestContent()
    fixture.time = 9.999; fixture.viewer.tick()
    #expect(fixture.viewer.isBusy)
    fixture.time = 10; fixture.viewer.tick()
    #expect(!fixture.viewer.isBusy)
    fixture.drain()
    #expect(fixture.viewerText == "local")
  }

  @Test func invalidOrderOversizeAndInvalidUTF8NeverWritePartialData() {
    var sent: [ScreenSharingClipboardMessage] = []
    var written: [ScreenSharingClipboardContent] = []
    let host = ScreenSharingClipboardTransfer(
      send: {
        sent.append($0); return true
      },
      canReceiveUnsolicited: { true }, read: { _ in .init(text: "") }, write: { written.append($0) })
    let id = UUID()
    host.receive(.begin(id: id, bytes: 65537))
    #expect(!host.isBusy)
    host.receive(.begin(id: id, bytes: 2))
    host.receive(.chunk(id: id, index: 1, data: Data([65, 66])))
    host.receive(.end(id: id))
    #expect(written.isEmpty && !host.isBusy)
    host.receive(.begin(id: id, bytes: 2))
    host.receive(.chunk(id: id, index: 0, data: Data([255, 255])))
    host.receive(.end(id: id))
    #expect(written.isEmpty && !host.isBusy)
  }

  @Test func losingAuthorizationBeforeCompletionCannotWriteClipboard() {
    var authorized = true
    var written = false
    let host = ScreenSharingClipboardTransfer(
      send: { _ in true }, canReceiveUnsolicited: { authorized },
      read: { _ in .init(text: "") }, write: { _ in written = true })
    let id = UUID()
    host.receive(.begin(id: id, bytes: 1))
    host.receive(.chunk(id: id, index: 0, data: Data([65])))
    authorized = false
    host.receive(.end(id: id))
    #expect(!written && !host.isBusy)
  }

  @Test func writeErrorsAndClosedChannelsEndTheTransfer() {
    let fixture = ClipboardFixture()
    fixture.rejectWrite = true
    fixture.viewer.sendContent(.init(text: "new"))
    fixture.drain()
    #expect(fixture.hostText == "remote")
    #expect(fixture.viewerResults.last! == "Fixture clipboard changed")
    fixture.connected = false
    fixture.viewer.requestContent()
    #expect(!fixture.viewer.isBusy)
    #expect(fixture.viewerResults.last!?.contains("unavailable") == true)
  }

  @Test func wirePayloadStaysBelowChannelLimitForLargestChunk() throws {
    let message = ScreenSharingClipboardMessage.chunk(id: UUID(), index: 31, data: Data(repeating: 255, count: 2048))
    let data = try message.encoded()
    #expect(data.count < 4096, "a host that predates rich content refuses larger messages")
    #expect(try ScreenSharingClipboardMessage.decode(data) == message)
    let rich = ScreenSharingClipboardMessage.chunk(
      id: UUID(), index: Int(Int32.max), data: Data(repeating: 255, count: ScreenSharingClipboardMessage.richChunkBytes)
    )
    #expect(try rich.encoded().count <= ScreenSharingClipboardMessage.maximumBytes)
    #expect(
      ScreenSharingClipboardMessage.richWindow * ScreenSharingClipboardMessage.maximumBytes <= 1024 * 1024,
      "a full window fits the clipboard channel's send buffer")
    #expect(throws: (any Error).self) {
      try ScreenSharingClipboardMessage.decode(
        Data(repeating: 0, count: ScreenSharingClipboardMessage.maximumBytes + 1))
    }
  }

  @Test func richContentRoundTripsEveryItemAndTypeWithABoundedWindow() {
    let fixture = ClipboardFixture(richContent: true)
    let image = Data((0..<600_000).map { UInt8(truncatingIfNeeded: $0 &* 31) })
    let content = ScreenSharingClipboardContent(items: [
      [
        .init(type: "public.png", data: image),
        .init(type: ScreenSharingClipboardContent.textType, data: Data("a".utf8)),
      ],
      [.init(type: "public.html", data: Data("<b>b</b>".utf8))],
    ])
    fixture.viewer.sendContent(content)
    fixture.drain()
    #expect(fixture.hostContent == content)
    #expect(fixture.viewerResults == [nil])
    #expect(fixture.maximumQueued == ScreenSharingClipboardMessage.richWindow)

    fixture.hostContent = .init(items: [[.init(type: "public.png", data: image)]])
    fixture.viewer.requestContent()
    fixture.drain()
    #expect(fixture.viewerContent == fixture.hostContent)
    #expect(fixture.viewerResults == [nil, nil])
  }

  @Test func aPeerWithoutRichContentGetsOnlyTheTextInTheFormatItAlreadyAccepts() {
    let fixture = ClipboardFixture()
    let image = ScreenSharingClipboardContent.Representation(type: "public.png", data: Data([1, 2, 3]))
    fixture.viewer.sendContent(.init(items: [[image]]))
    #expect(fixture.viewerResults == ["The clipboard does not contain plain text."])
    #expect(!fixture.viewer.isBusy)
    fixture.drain()

    let text = ScreenSharingClipboardContent.Representation(
      type: ScreenSharingClipboardContent.textType, data: Data("caption".utf8))
    fixture.viewer.sendContent(.init(items: [[image, text]]))
    guard case .begin(_, let bytes, nil) = fixture.queue.first?.message else {
      Issue.record("expected a plain-text begin"); return
    }
    #expect(bytes == 7)
    fixture.drain()
    #expect(fixture.hostContent == .init(text: "caption"))
  }

  @Test func eachKindOfTransferIsHeldToItsOwnSizeLimits() throws {
    var written: [ScreenSharingClipboardContent] = []
    var sent: [ScreenSharingClipboardMessage] = []
    let host = ScreenSharingClipboardTransfer(
      send: {
        sent.append($0); return true
      }, canReceiveUnsolicited: { true },
      read: { _ in .init(text: "") }, write: { written.append($0) })
    host.receive(.begin(id: UUID(), bytes: ScreenSharingClipboardMessage.maximumContentBytes + 1, richContent: true))
    #expect(!host.isBusy)
    let text = UUID()
    host.receive(.begin(id: text, bytes: 4096))
    host.receive(
      .chunk(id: text, index: 0, data: Data(repeating: 65, count: ScreenSharingClipboardMessage.chunkBytes + 1)))
    #expect(!host.isBusy)

    let archive = try ScreenSharingClipboardContent(
      items: [[.init(type: "public.png", data: Data(repeating: 7, count: 100_000))]]
    ).archived()
    let rich = UUID()
    host.receive(.begin(id: rich, bytes: archive.count, richContent: true))
    #expect(host.isBusy)
    host.receive(.chunk(id: rich, index: 0, data: archive.prefix(ScreenSharingClipboardMessage.richChunkBytes)))
    host.receive(.chunk(id: rich, index: 1, data: archive.dropFirst(ScreenSharingClipboardMessage.richChunkBytes)))
    #expect(!host.isBusy && written.isEmpty, "a chunk larger than the rich chunk size is refused")
    #expect(sent.last == .result(id: rich, error: "Invalid clipboard chunk."))
  }

  @Test func theArchiveIsTheByteFormatTheLinuxServerReadsAndWrites() throws {
    let hex =
      "00000002000000020000000a7075626c69632e706e6700000003010203000000167075626c69632e757466382d706c61696e2d74657874000000026869000000010000000b7075626c69632e68746d6c000000033c623e"
    let archive = Data(
      stride(from: 0, to: hex.count, by: 2).map {
        UInt8(hex[hex.index(hex.startIndex, offsetBy: $0)...].prefix(2), radix: 16)!
      })
    let content = ScreenSharingClipboardContent(items: [
      [
        .init(type: "public.png", data: Data([1, 2, 3])),
        .init(type: ScreenSharingClipboardContent.textType, data: Data("hi".utf8)),
      ],
      [.init(type: "public.html", data: Data("<b>".utf8))],
    ])
    #expect(try content.archived() == archive)
    #expect(try ScreenSharingClipboardContent.unarchived(archive) == content)
    #expect(throws: (any Error).self) { try ScreenSharingClipboardContent.unarchived(archive.dropLast()) }
    #expect(throws: (any Error).self) { try ScreenSharingClipboardContent.unarchived(archive + Data([0])) }
    #expect(throws: (any Error).self) { try ScreenSharingClipboardContent.unarchived(Data(count: 4)) }
  }

  @Test func onlyATransferThatStopsProgressingTimesOut() {
    let fixture = ClipboardFixture(richContent: true)
    let content = ScreenSharingClipboardContent(items: [[.init(type: "public.png", data: Data(count: 400_000))]])
    fixture.viewer.sendContent(content)
    while !fixture.queue.isEmpty {
      for _ in 0..<fixture.queue.count { fixture.deliverOne() }
      fixture.time += 4
      fixture.viewer.tick(); fixture.host.tick()
    }
    #expect(fixture.time > 20)
    #expect(fixture.hostContent == content && fixture.viewerResults == [nil])

    fixture.viewer.sendContent(content)
    fixture.deliverOne(); fixture.deliverOne()
    fixture.time += 9.999; fixture.viewer.tick()
    #expect(fixture.viewer.isBusy)
    fixture.time += 0.001; fixture.viewer.tick()
    #expect(!fixture.viewer.isBusy)
    #expect(fixture.viewerResults.last == "Clipboard transfer timed out. Try again.")
  }
}

@MainActor
private final class ClipboardFixture {
  var time = 0.0
  var hostContent = ScreenSharingClipboardContent(text: "remote")
  var viewerContent = ScreenSharingClipboardContent(text: "local")
  var hostText: String? {
    get { hostContent.text }
    set { hostContent = .init(text: newValue ?? "") }
  }
  var viewerText: String? { viewerContent.text }
  let richContent: Bool
  var rejectWrite = false
  var connected = true
  var maximumQueued = 0
  var viewerResults: [String?] = []
  var hostResults: [String?] = []
  var queue: [(host: Bool, message: ScreenSharingClipboardMessage)] = []
  lazy var viewer = make(host: false)
  lazy var host = make(host: true)
  init(richContent: Bool = false) { self.richContent = richContent }
  private func make(host: Bool) -> ScreenSharingClipboardTransfer {
    let transfer = ScreenSharingClipboardTransfer(
      send: { [unowned self] in
        guard connected else { return false }
        queue.append((host: !host, message: $0)); maximumQueued = max(maximumQueued, queue.count); return true
      }, now: { [unowned self] in time }, canReceiveUnsolicited: { host },
      read: { [unowned self] _ in host ? hostContent : viewerContent },
      write: { [unowned self] content in
        if rejectWrite { throw ScreenSharingError.invalid("Fixture clipboard changed") }
        if host { hostContent = content } else { viewerContent = content }
      })
    transfer.richContent = richContent
    transfer.onFinished = { [unowned self] error in
      if host { hostResults.append(error) } else { viewerResults.append(error) }
    }
    return transfer
  }
  func deliverOne() {
    guard !queue.isEmpty else { return }
    let next = queue.removeFirst()
    if next.host { host.receive(next.message) } else { viewer.receive(next.message) }
  }
  func drain() { while !queue.isEmpty { deliverOne() } }
}
