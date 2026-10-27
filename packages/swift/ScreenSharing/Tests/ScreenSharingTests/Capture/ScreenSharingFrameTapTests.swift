import CoreVideo
import Foundation
import Testing
@testable import ScreenSharing

struct ScreenSharingFrameTapTests {
  private func frame(_ timestamp: Int64) throws -> ScreenSharingVideoFrame {
    var pixel: CVPixelBuffer?
    #expect(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, nil, &pixel) == kCVReturnSuccess)
    return ScreenSharingVideoFrame(pixelBuffer: try #require(pixel), timestampNs: timestamp)
  }

  @Test func everyTapReceivesEachFrameIndependentlyOfTheSource() throws {
    let source = ScreenSharingFrameMailbox()
    let first = source.tap(UUID())
    let second = source.tap(UUID())

    source.put(try frame(1))

    #expect(source.take()?.timestampNs == 1)
    #expect(first.take()?.timestampNs == 1)
    #expect(second.take()?.timestampNs == 1)
    #expect(first.take() == nil)
  }

  @Test func lateTapStartsWithTheLatestFrameAndUntappedCopiesStop() throws {
    let source = ScreenSharingFrameMailbox()
    source.retainsLatest = true
    source.put(try frame(1))
    source.put(try frame(2))
    _ = source.take()
    let id = UUID()

    let late = source.tap(id)
    #expect(late.take()?.timestampNs == 2)

    source.untap(id)
    source.put(try frame(3))
    #expect(late.take() == nil)
    #expect(source.take()?.timestampNs == 3)
  }

  @Test func aMailboxOnlyKeepsTheLatestFrameWhileAskedTo() throws {
    let source = ScreenSharingFrameMailbox()
    source.put(try frame(1))
    _ = source.take()
    #expect(source.tap(UUID()).take() == nil)

    source.retainsLatest = true
    source.put(try frame(2))
    _ = source.take()
    source.retainsLatest = false
    #expect(source.tap(UUID()).take() == nil)
  }

  @Test func tappingTheSameIdReturnsTheSameCopy() {
    let source = ScreenSharingFrameMailbox()
    let id = UUID()
    #expect(source.tap(id) === source.tap(id))
  }

  @Test func tapNotifiesItsConsumerWhenAFrameArrives() throws {
    let source = ScreenSharingFrameMailbox()
    let tap = source.tap(UUID())
    let notified = NotifiedFlag()
    tap.onFrameAvailable { notified.set() }

    source.put(try frame(1))

    #expect(notified.value)
  }
}

private final class NotifiedFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var flag = false
  var value: Bool { lock.withLock { flag } }
  func set() { lock.withLock { flag = true } }
}
