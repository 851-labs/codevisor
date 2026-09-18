import Foundation
import Testing

@testable import ScreenSharing

/// The lease's data plane: what actually reaches the control channel for a
/// stream of captured events, and what the viewer is told when the channel
/// stops accepting them.
@MainActor
struct ScreenSharingInputForwarderTests {
  @Test func everyForwardedEventIsNumberedInOrderUnderTheLease() {
    let channel = RecordingChannel()
    let forwarder = ScreenSharingInputForwarder(send: channel.send)
    let lease = UUID()
    forwarder.begin(lease: lease)
    #expect(forwarder.isActive)
    let events: [ScreenSharingInputEvent] = [
      .button(.init(x: 0.25, y: 0.5), button: 0, down: true, clicks: 1, modifiers: 0),
      .move(.init(x: 0.5, y: 0.5), modifiers: 0),
      .button(.init(x: 0.5, y: 0.5), button: 0, down: false, clicks: 1, modifiers: 0),
    ]
    for event in events { forwarder.forward(event) }
    #expect(
      channel.messages
        == events.enumerated().map {
          .input(lease: lease, sequence: UInt64($0.offset + 1), event: $0.element)
        })
  }

  @Test func aSecondLeaseRestartsNumberingFromOne() {
    let channel = RecordingChannel()
    let forwarder = ScreenSharingInputForwarder(send: channel.send)
    forwarder.begin(lease: UUID())
    forwarder.forward(.key(code: 0, down: true, repeatKey: false, modifiers: 0))
    let second = UUID()
    forwarder.begin(lease: second)
    forwarder.forward(.key(code: 0, down: false, repeatKey: false, modifiers: 0))
    #expect(
      channel.messages.last
        == .input(lease: second, sequence: 1, event: .key(code: 0, down: false, repeatKey: false, modifiers: 0)))
    #expect(forwarder.lease == second)
  }

  @Test func eventsOutsideALeaseAreDropped() {
    let channel = RecordingChannel()
    let forwarder = ScreenSharingInputForwarder(send: channel.send)
    forwarder.forward(.move(.init(x: 0.5, y: 0.5), modifiers: 0))
    #expect(channel.messages.isEmpty)
    #expect(!forwarder.isActive)
    forwarder.begin(lease: UUID())
    forwarder.forward(.move(.init(x: 0.5, y: 0.5), modifiers: 0))
    forwarder.end()
    forwarder.forward(.move(.init(x: 0.25, y: 0.5), modifiers: 0))
    #expect(channel.messages.count == 1)
    #expect(forwarder.lease == nil)
  }

  /// The host revokes the lease over a single invalid event, so an event the
  /// local surface somehow produced out of range must never take a sequence
  /// number, let alone reach the wire.
  @Test(
    arguments: [
      ScreenSharingInputEvent.move(.init(x: -0.01, y: 0.5), modifiers: 0),
      .move(.init(x: 0.5, y: 1.01), modifiers: 0),
      .move(.init(x: .nan, y: 0.5), modifiers: 0),
      .button(.init(x: 0.5, y: 0.5), button: 3, down: true, clicks: 1, modifiers: 0),
      .button(.init(x: 0.5, y: 0.5), button: 0, down: true, clicks: 0, modifiers: 0),
      .scroll(.init(x: 0.5, y: 0.5), x: 0, y: 4097, modifiers: 0),
      .key(code: 127, down: true, repeatKey: false, modifiers: 0),
      .key(code: 0, down: true, repeatKey: false, modifiers: 64),
      .text(""),
    ])
  func anInvalidEventIsDroppedWithoutConsumingASequence(event: ScreenSharingInputEvent) {
    let channel = RecordingChannel()
    let forwarder = ScreenSharingInputForwarder(send: channel.send)
    let lease = UUID()
    forwarder.begin(lease: lease)
    forwarder.forward(event)
    #expect(channel.messages.isEmpty)
    let valid = ScreenSharingInputEvent.move(.init(x: 0.5, y: 0.5), modifiers: 0)
    forwarder.forward(valid)
    #expect(channel.messages == [.input(lease: lease, sequence: 1, event: valid)])
    #expect(forwarder.isActive, "a malformed event is not a reason to drop the lease")
  }

  @Test func aRefusedSendEndsForwardingAndReportsTheLossExactlyOnce() {
    let channel = RecordingChannel()
    let forwarder = ScreenSharingInputForwarder(send: channel.send)
    var losses: [String?] = []
    forwarder.onLost = { losses.append($0) }
    forwarder.begin(lease: UUID())
    forwarder.forward(.move(.init(x: 0.5, y: 0.5), modifiers: 0))
    channel.accepts = false
    forwarder.forward(.move(.init(x: 0.25, y: 0.5), modifiers: 0))
    #expect(!forwarder.isActive)
    #expect(losses.count == 1)
    #expect(losses.first??.contains("Request control again") == true)

    channel.accepts = true
    forwarder.forward(.move(.init(x: 0.75, y: 0.5), modifiers: 0))
    #expect(channel.messages.count == 2, "the refused event is the last one attempted")
    #expect(losses.count == 1, "the loss is reported once, not on every later event")
  }
}

@MainActor
private final class RecordingChannel {
  var accepts = true
  private(set) var messages: [ScreenSharingControlMessage] = []
  lazy var send: (ScreenSharingControlMessage) -> Bool = { [unowned self] message in
    messages.append(message)
    return accepts
  }
}
