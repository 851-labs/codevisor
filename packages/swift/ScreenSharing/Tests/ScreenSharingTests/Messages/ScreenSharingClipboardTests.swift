import Foundation
import Testing
@testable import ScreenSharing

@MainActor
struct ScreenSharingClipboardTests {
  @Test func explicitRoundTripsPreserveUnicodeAcrossChunkBoundariesAndBoundTheQueue() throws {
    let fixture = ClipboardFixture()
    let value = String(repeating: "é👩🏽‍💻日本語\n", count: 1500)
    fixture.viewer.sendText(value)
    #expect(fixture.viewer.isBusy)
    fixture.drain()
    #expect(fixture.hostText == value)
    #expect(fixture.maximumQueued <= 1)
    #expect(!fixture.viewer.isBusy && !fixture.host.isBusy)
    #expect(fixture.viewerResults.last! == nil)
    fixture.hostText = "Remote clipboard ✓"
    fixture.viewer.requestText()
    fixture.drain()
    #expect(fixture.viewerText == fixture.hostText)
    #expect(fixture.viewerResults.count == 2)
  }

  @Test func viewerRejectsUnrequestedClipboardAndNeverChangesItsPasteboard() {
    let fixture = ClipboardFixture()
    fixture.host.sendText("unsolicited")
    fixture.drain()
    #expect(fixture.viewerText == "local")
    #expect(fixture.hostResults.last! != nil)
    #expect(!fixture.host.isBusy)
  }

  @Test func lateChunksCannotCompleteAfterCancellationOrTimeout() {
    let fixture = ClipboardFixture()
    fixture.viewer.requestText()
    fixture.deliverOne()
    fixture.deliverOne()
    fixture.viewer.cancel()
    fixture.drain()
    #expect(fixture.viewerText == "local")
    #expect(!fixture.host.isBusy && !fixture.viewer.isBusy)

    fixture.viewer.requestText()
    fixture.time = 9.999; fixture.viewer.tick()
    #expect(fixture.viewer.isBusy)
    fixture.time = 10; fixture.viewer.tick()
    #expect(!fixture.viewer.isBusy)
    fixture.drain()
    #expect(fixture.viewerText == "local")
  }

  @Test func invalidOrderOversizeAndInvalidUTF8NeverWritePartialData() {
    var sent: [ScreenSharingClipboardMessage] = []
    var written: [String] = []
    let host = ScreenSharingClipboardTransfer(
      send: {
        sent.append($0); return true
      },
      canReceiveUnsolicited: { true }, read: { "" }, write: { written.append($0) })
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
      read: { "" }, write: { _ in written = true })
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
    fixture.viewer.sendText("new")
    fixture.drain()
    #expect(fixture.hostText == "remote")
    #expect(fixture.viewerResults.last! == "Fixture clipboard changed")
    fixture.connected = false
    fixture.viewer.requestText()
    #expect(!fixture.viewer.isBusy)
    #expect(fixture.viewerResults.last!?.contains("unavailable") == true)
  }

  @Test func wirePayloadStaysBelowChannelLimitForLargestChunk() throws {
    let message = ScreenSharingClipboardMessage.chunk(id: UUID(), index: 31, data: Data(repeating: 255, count: 2048))
    let data = try message.encoded()
    #expect(data.count < 4096)
    #expect(try ScreenSharingClipboardMessage.decode(data) == message)
    #expect(throws: (any Error).self) { try ScreenSharingClipboardMessage.decode(Data(repeating: 0, count: 4097)) }
  }
}

@MainActor
private final class ClipboardFixture {
  var time = 0.0
  var hostText = "remote"
  var viewerText = "local"
  var rejectWrite = false
  var connected = true
  var maximumQueued = 0
  var viewerResults: [String?] = []
  var hostResults: [String?] = []
  var queue: [(host: Bool, message: ScreenSharingClipboardMessage)] = []
  lazy var viewer = make(host: false)
  lazy var host = make(host: true)
  private func make(host: Bool) -> ScreenSharingClipboardTransfer {
    let transfer = ScreenSharingClipboardTransfer(
      send: { [unowned self] in
        guard connected else { return false }
        queue.append((host: !host, message: $0)); maximumQueued = max(maximumQueued, queue.count); return true
      }, now: { [unowned self] in time }, canReceiveUnsolicited: { host },
      read: { [unowned self] in host ? hostText : viewerText },
      write: { [unowned self] text in
        if rejectWrite { throw ScreenSharingError.invalid("Fixture clipboard changed") }
        if host { hostText = text } else { viewerText = text }
      })
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
