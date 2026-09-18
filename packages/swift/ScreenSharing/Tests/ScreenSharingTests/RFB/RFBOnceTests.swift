import CodevisorTestSupport
import Foundation
import Testing
@testable import ScreenSharing

/// The guard that keeps a Network.framework state handler from resuming a
/// continuation twice — a second resume is a crash, not a wrong answer.
struct RFBOnceTests {
  @Test func theFirstClaimWinsAndEveryLaterOneLoses() {
    let once = RFBOnce()
    #expect(once.claim())
    #expect(!once.claim())
    #expect(!once.claim())
  }

  @Test func separateGuardsDoNotShareState() {
    let first = RFBOnce(), second = RFBOnce()
    #expect(first.claim())
    #expect(second.claim())
  }

  /// Every caller reaches the gate before any of them is released, so the
  /// claims genuinely contend rather than running one after another.
  @Test func exactlyOneOfManyConcurrentCallersWins() async {
    let callers = 64
    let once = RFBOnce()
    let arrived = TestSignal(), gate = TestSignal()
    let winners = await withTaskGroup(of: Bool.self) { group in
      for _ in 0..<callers {
        group.addTask {
          arrived.signal()
          await gate.wait()
          return once.claim()
        }
      }
      await arrived.wait(for: callers)
      gate.signal()
      return await group.reduce(into: 0) { $0 += $1 ? 1 : 0 }
    }
    #expect(winners == 1)
  }
}
