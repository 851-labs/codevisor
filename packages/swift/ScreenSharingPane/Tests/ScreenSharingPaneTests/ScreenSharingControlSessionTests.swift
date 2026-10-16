import CodevisorTestSupport
import Foundation
import ScreenSharing
import Testing

@testable import ScreenSharingPane

@MainActor
@Suite("Control lease from a touch viewer")
struct ScreenSharingControlSessionTests {
  let clock = TestClock()
  let viewer: ScreenSharingLocalChannel<ScreenSharingControlMessage>
  let host: ScreenSharingLocalChannel<ScreenSharingControlMessage>
  let received = Recorder()
  let requestID = UUID()
  let lease = UUID()
  let point = ScreenSharingPointer(x: 0.5, y: 0.5)

  final class Recorder {
    var messages: [ScreenSharingControlMessage] = []
  }

  init() {
    (viewer, host) = ScreenSharingLocalChannel<ScreenSharingControlMessage>.pair(hop: { work in
      MainActor.assumeIsolated { work() }
    })
    host.onMessage = { [received] in received.messages.append($0) }
  }

  private func session() -> ScreenSharingControlSession {
    ScreenSharingControlSession(channel: viewer, clock: clock, makeID: { [requestID] in requestID })
  }

  private var inputs: [UInt64] {
    received.messages.compactMap {
      guard case .input(_, let sequence, _) = $0 else { return nil }
      return sequence
    }
  }

  @Test("The first touch asks for control and is delivered, in order, once the Mac grants it")
  func requestThenDeliver() {
    let control = session()
    control.send([.move(point, modifiers: 0), .button(point, button: 0, down: true, clicks: 1, modifiers: 0)])
    #expect(control.state == .requesting)
    #expect(received.messages == [.request(id: requestID)])
    control.send([.button(point, button: 0, down: false, clicks: 1, modifiers: 0)])
    #expect(received.messages.count == 1)

    host.send(.grant(request: requestID, lease: lease))
    #expect(control.state == .controlling)
    #expect(inputs == [1, 2, 3])

    control.send([.move(point, modifiers: 0)])
    #expect(inputs == [1, 2, 3, 4])
  }

  @Test("A denial drops the queued touches and explains why")
  func denied() {
    let control = session()
    control.send([.move(point, modifiers: 0)])
    host.send(.denied(request: requestID, reason: "Allow Accessibility on the Mac."))
    #expect(control.state == .idle)
    #expect(control.notice == "Allow Accessibility on the Mac.")
    #expect(inputs.isEmpty)
  }

  @Test("An unanswered request gives up after three seconds")
  func requestTimeout() async {
    let control = session()
    control.send([.move(point, modifiers: 0)])
    await clock.waitForSleep(ScreenSharingControlSession.requestTimeout)
    clock.advance(by: .seconds(2.999))
    #expect(control.state == .requesting)
    clock.advance(by: .milliseconds(1))
    await awaitObserved { control.state == .idle }
    #expect(control.notice == "The Mac didn't answer the request for control.")
  }

  @Test("Control is kept alive every second and released on request")
  func heartbeatAndRelease() async {
    let control = session()
    control.send([.move(point, modifiers: 0)])
    host.send(.grant(request: requestID, lease: lease))
    await clock.waitForSleep(ScreenSharingControlSession.heartbeatInterval)
    clock.advance(by: .seconds(1))
    await clock.waitForSleep(ScreenSharingControlSession.heartbeatInterval, count: 2)
    #expect(received.messages.last == .heartbeat(lease: lease))

    control.release()
    #expect(control.state == .idle)
    #expect(received.messages.last == .release(lease: lease))
    #expect(control.notice == nil)
  }

  @Test("The Mac revoking control returns to viewing with its reason")
  func revoked() {
    let control = session()
    control.send([.move(point, modifiers: 0)])
    host.send(.grant(request: requestID, lease: lease))
    host.send(.revoked(lease: lease, reason: "Stopped sharing on the Mac."))
    #expect(control.state == .idle)
    #expect(control.notice == "Stopped sharing on the Mac.")
    control.send([.move(point, modifiers: 0)])
    #expect(control.state == .requesting)
  }
}
