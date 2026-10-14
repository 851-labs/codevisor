import CodevisorTestSupport
import Foundation
import Observation
import Testing
@testable import ScreenSharing

@MainActor
struct VNCControlLeaseTests {
  final class FakeChannel: RFBControlChannel, @unchecked Sendable {
    var onControlText: (@Sendable (String) -> Void)?
    let (sends, continuation) = AsyncStream<String>.makeStream()
    func sendControlText(_ text: String) async throws { continuation.yield(text) }
  }

  @MainActor
  @Observable
  final class Viewer {
    private(set) var received: [ScreenSharingControlMessage] = []
    init(_ emulator: VNCHostEmulator) {
      emulator.controlChannel.onMessage = { [weak self] in self?.received.append($0) }
    }
  }

  @MainActor
  @Observable
  final class Outbox {
    var messages: [RFBClientMessage] = []
  }

  func emulator(channel: FakeChannel?) -> (VNCHostEmulator, Viewer, () -> [RFBClientMessage]) {
    let outbox = Outbox()
    let translator = VNCInputTranslator(width: 100, height: 100, keys: VNCKeyTranslator { _, _ in nil })
    let emulator = VNCHostEmulator(translator: translator, leaseChannel: channel, viewerName: "Studio") {
      outbox.messages.append($0)
    }
    return (emulator, Viewer(emulator), { outbox.messages })
  }

  @Test func theServerGrantsAndRevokesControl() async throws {
    let channel = FakeChannel()
    let (emulator, viewer, outbox) = emulator(channel: channel)
    var sends = channel.sends.makeAsyncIterator()
    let request = UUID()
    emulator.controlChannel.send(.request(id: request))
    let sent = try #require(await sends.next())
    #expect(
      try JSONSerialization.jsonObject(with: Data(sent.utf8)) as? [String: String]
        == ["type": "request", "name": "Studio"])
    #expect(viewer.received.isEmpty, "nothing is granted until the server says so")
    emulator.serverLease(.granted)
    await awaitObserved { viewer.received.count == 1 }
    guard case .grant(request, let lease)? = viewer.received.last else {
      Issue.record("expected a grant, got \(viewer.received)")
      return
    }
    emulator.controlChannel.send(
      .input(
        lease: lease, sequence: 1,
        event: .button(.init(x: 0.5, y: 0.5), button: 0, down: true, clicks: 1, modifiers: 0)))
    await awaitObserved { outbox().count == 1 }
    emulator.serverLease(.revoked(by: "Laptop"))
    await awaitObserved { viewer.received.count == 2 }
    #expect(viewer.received.last == .revoked(lease: lease, reason: "Laptop took control."))
    #expect(outbox().last == .pointerEvent(buttons: 0, x: 50, y: 50))
    emulator.serverLease(.granted)
    emulator.serverLease(.revoked(by: "Laptop"))
    let again = UUID()
    emulator.controlChannel.send(.request(id: again))
    _ = await sends.next()
    emulator.serverLease(.granted)
    await awaitObserved { viewer.received.count == 3 }
    guard case .grant(again, _)? = viewer.received.last else {
      Issue.record("expected the second grant, got \(viewer.received)")
      return
    }
  }

  @Test func releasingTellsTheServer() async {
    let channel = FakeChannel()
    let (emulator, viewer, _) = emulator(channel: channel)
    var sends = channel.sends.makeAsyncIterator()
    emulator.controlChannel.send(.request(id: UUID()))
    _ = await sends.next()
    emulator.serverLease(.granted)
    await awaitObserved { viewer.received.count == 1 }
    guard case .grant(_, let lease)? = viewer.received.last else {
      Issue.record("expected a grant")
      return
    }
    emulator.controlChannel.send(.release(lease: lease))
    #expect(await sends.next() == #"{"type":"release"}"#)
  }

  @Test func withoutAChannelControlIsGrantedLocally() async {
    let (emulator, viewer, _) = emulator(channel: nil)
    let request = UUID()
    emulator.controlChannel.send(.request(id: request))
    await awaitObserved { viewer.received.count == 1 }
    guard case .grant(request, _)? = viewer.received.last else {
      Issue.record("expected an immediate grant")
      return
    }
  }

  @Test func leaseMessagesDecodeAndEncode() throws {
    #expect(RFBControlLeaseMessage.decode(#"{"type":"granted"}"#) == .granted)
    #expect(RFBControlLeaseMessage.decode(#"{"type":"revoked","by":"Laptop"}"#) == .revoked(by: "Laptop"))
    #expect(RFBControlLeaseMessage.decode(#"{"type":"revoked"}"#) == .revoked(by: "Another viewer"))
    #expect(RFBControlLeaseMessage.decode(#"{"type":"other"}"#) == nil)
    #expect(RFBControlLeaseMessage.decode("not json") == nil)
    let request = try #require(
      try JSONSerialization.jsonObject(with: Data(RFBControlLeaseMessage.request(name: "Mac \"1\"").utf8))
        as? [String: String])
    #expect(request == ["type": "request", "name": "Mac \"1\""])
  }
}
