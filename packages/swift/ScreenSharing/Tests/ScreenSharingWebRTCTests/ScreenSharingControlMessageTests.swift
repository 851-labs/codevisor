import Foundation
import Testing
@testable import ScreenSharing
@testable import ScreenSharingWebRTC

struct ScreenSharingControlMessageTests {
  @Test func wireFormatRejectsUnsupportedVersionsOversizeAndInvalidInput() throws {
    let id = UUID()
    let message = ScreenSharingControlMessage.input(
      lease: id, sequence: 2, event: .button(.init(x: 0.1, y: 0.9), button: 2, down: true, clicks: 2, modifiers: 9))
    #expect(try ScreenSharingControlMessage.decode(message.encoded()) == message)
    let data = try message.encoded()
    var object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    object["version"] = 2
    let unsupported = try JSONSerialization.data(withJSONObject: object)
    #expect(throws: (any Error).self) { try ScreenSharingControlMessage.decode(unsupported) }
    #expect(throws: (any Error).self) { try ScreenSharingControlMessage.decode(Data(repeating: 0, count: 4097)) }
    let invalid = ScreenSharingControlMessage.input(
      lease: id, sequence: 1, event: .key(code: 65535, down: true, repeatKey: false, modifiers: 0))
    #expect(throws: (any Error).self) { try ScreenSharingControlMessage.decode(invalid.encoded()) }
    #expect(!ScreenSharingInputEvent.move(.init(x: .nan, y: 0), modifiers: 0).isValid)
    #expect(!ScreenSharingInputEvent.scroll(.init(x: 0, y: 0), x: .min, y: 0, modifiers: 0).isValid)
    #expect(!ScreenSharingInputEvent.text(String(repeating: "x", count: 1025)).isValid)
  }

  /// 851-2469: Apps, Mission Control and Desktop travel as the Mac's own keys; other codes above
  /// the keyboard range stay invalid.
  @Test func systemKeysAreValidInputAndOtherHighCodesAreNot() {
    for key in ScreenSharingSystemKey.allCases {
      #expect(ScreenSharingInputEvent.key(code: key.rawValue, down: true, repeatKey: false, modifiers: 0).isValid)
    }
    #expect(ScreenSharingSystemKey.missionControl.rawValue == 160 && ScreenSharingSystemKey.apps.rawValue == 131)
    #expect(!ScreenSharingInputEvent.key(code: 127, down: true, repeatKey: false, modifiers: 0).isValid)
    #expect(!ScreenSharingInputEvent.key(code: 200, down: true, repeatKey: false, modifiers: 0).isValid)
  }

  @Test func geometryExcludesLetterboxingAndClampsOnlyAnActiveDrag() {
    func pointer(_ x: Double, _ y: Double, clamp: Bool = false) -> ScreenSharingPointer? {
      ScreenSharingVideoGeometry.pointer(
        x: x, y: y, surfaceWidth: 1000, surfaceHeight: 1000,
        videoWidth: 1920, videoHeight: 1080, clamp: clamp)
    }
    #expect(pointer(500, 500) == .init(x: 0.5, y: 0.5))
    #expect(pointer(500, 100) == nil)
    #expect(pointer(-10, 500) == nil)
    #expect(pointer(-10, 500, clamp: true) == .init(x: 0, y: 0.5))
    #expect(pointer(500, 100, clamp: true) == .init(x: 0.5, y: 0))
    #expect(
      ScreenSharingVideoGeometry.pointer(
        x: 100, y: 100, surfaceWidth: 0, surfaceHeight: 100,
        videoWidth: 100, videoHeight: 100) == nil)
  }

  @Test func incomingControlHasBoundedBytesAndMessageCountEvenForEmptyPackets() {
    var inbox = ScreenSharingControlInbox()
    #expect(inbox.enqueue(Data()) == true)
    for _ in 1..<256 { #expect(inbox.enqueue(Data()) == false) }
    #expect(inbox.enqueue(Data()) == false)
    let overflow = inbox.drain()
    #expect(overflow.0.count == 256 && overflow.1)
    inbox.stop()
    #expect(inbox.enqueue(Data([1])) == false)
    #expect(inbox.drain().0.isEmpty)

    var bytes = ScreenSharingControlInbox()
    for index in 0..<16 { #expect(bytes.enqueue(Data(repeating: UInt8(index), count: 4096)) == (index == 0)) }
    let batch = bytes.drain()
    #expect(!batch.1)
    #expect(batch.0.map { $0.first! } == Array(UInt8(0)..<16))
    let released = bytes.finish()
    #expect(!released)
    #expect(bytes.enqueue(Data(repeating: 1, count: 4097)) == true)
    #expect(bytes.drain().1)
  }

  /// The cursor channel admits pointer images (851-2377): a full-size message, and several in one drain.
  @Test func theCursorChannelAdmitsImagesTheControlChannelWouldRefuse() {
    var cursor = ScreenSharingControlInbox(limits: .cursor)
    let image = Data(repeating: 7, count: ScreenSharingCursorMessage.maximumBytes)
    for _ in 0..<8 { _ = cursor.enqueue(image) }
    let batch = cursor.drain()
    #expect(batch.0.count == 8 && !batch.1)
    _ = cursor.enqueue(Data(repeating: 7, count: ScreenSharingCursorMessage.maximumBytes + 1))
    #expect(cursor.drain().1)

    var control = ScreenSharingControlInbox(limits: .control)
    _ = control.enqueue(image)
    #expect(control.drain().1)
  }

  @Test func packetsAreBatchedInArrivalOrderAndOnlyTheFirstOfABatchSchedulesADrain() {
    var inbox = ScreenSharingControlInbox()
    // Only the arrival that finds no drain outstanding asks for one; the rest
    // of the batch rides along with it.
    #expect(inbox.enqueue(Data([1])) == true)
    #expect(inbox.enqueue(Data([2])) == false)
    #expect(inbox.enqueue(Data([3])) == false)
    let batch = inbox.drain()
    #expect(batch.0 == [Data([1]), Data([2]), Data([3])] && !batch.1)
    #expect(inbox.drain().0.isEmpty)
    // Finishing a drain with nothing new releases the schedule, so the next
    // arrival asks for a new one rather than waiting for a drain that will never come.
    let released = inbox.finish()
    #expect(!released)
    #expect(inbox.enqueue(Data([4])) == true)
    #expect(inbox.drain().0 == [Data([4])])
  }

  /// A drain stays outstanding until its batch was delivered (on the main actor, for most
  /// channels): what arrives meanwhile waits within the limits instead of scheduling a second
  /// delivery, and finishing reports it so the same drain takes it next.
  @Test func arrivalsWhileABatchIsBeingDeliveredWaitForTheSameDrain() {
    var inbox = ScreenSharingControlInbox()
    #expect(inbox.enqueue(Data([1])) == true)
    #expect(inbox.drain().0 == [Data([1])])
    #expect(inbox.enqueue(Data([2])) == false, "the first batch is still being delivered")
    #expect(inbox.enqueue(Data([3])) == false)
    let pending = inbox.finish()
    #expect(pending, "more arrived: drain again")
    #expect(inbox.drain().0 == [Data([2]), Data([3])])
    let released = inbox.finish()
    #expect(!released)
    #expect(inbox.enqueue(Data([4])) == true)
    // A stalled delivery bounds the backlog exactly as before: 256 messages, then failure.
    for _ in 0..<256 { _ = inbox.enqueue(Data()) }
    let overflow = inbox.drain()
    #expect(overflow.1 && overflow.0.count == 256)
  }

  @Test func aDrainRestoresTheByteBudgetButNeverClearsAFailure() {
    var inbox = ScreenSharingControlInbox()
    let full = Data(repeating: 9, count: ScreenSharingControlMessage.maximumBytes)
    for _ in 0..<16 { _ = inbox.enqueue(full) }
    let first = inbox.drain()
    #expect(first.0.count == 16 && !first.1)
    // A second batch of the same size still fits, so the budget went out with
    // the packets instead of accumulating across drains.
    for _ in 0..<16 { _ = inbox.enqueue(full) }
    let second = inbox.drain()
    #expect(second.0.count == 16 && !second.1)
    let released = inbox.finish()
    #expect(!released)

    #expect(inbox.enqueue(Data(repeating: 9, count: ScreenSharingControlMessage.maximumBytes + 1)) == true)
    let failure = inbox.drain()
    #expect(failure.0.isEmpty && failure.1)
    // The failure latches, because the channel is torn down on it: nothing
    // after it is admitted, finishing never releases the drain, and every
    // later drain keeps reporting it.
    let pending = inbox.finish()
    #expect(pending)
    #expect(inbox.enqueue(Data([1])) == false)
    let after = inbox.drain()
    #expect(after.0.isEmpty && after.1)
  }

  @Test func fractionalTrackpadMovementIsPreservedAndInvalidDeltasDoNotContaminateIt() {
    var scroll = ScreenSharingScrollAccumulator()
    #expect(scroll.add(x: 0.4, y: -0.4) == (0, 0))
    #expect(scroll.add(x: 0.4, y: -0.4) == (0, 0))
    #expect(scroll.add(x: .infinity, y: 0) == (0, 0))
    #expect(scroll.add(x: 0.4, y: -0.4) == (1, -1))
    #expect(scroll.add(x: 100_000, y: -100_000) == (4096, -4096))
  }

  @Test func geometryMapsTheVideoCornersOfAWiderSurface() {
    #expect(
      ScreenSharingVideoGeometry.pointer(
        x: 500, y: 0, surfaceWidth: 2000, surfaceHeight: 600,
        videoWidth: 1000, videoHeight: 600) == .init(x: 0, y: 0))
    #expect(
      ScreenSharingVideoGeometry.pointer(
        x: 1500, y: 600, surfaceWidth: 2000, surfaceHeight: 600,
        videoWidth: 1000, videoHeight: 600) == .init(x: 1, y: 1))
  }
}
