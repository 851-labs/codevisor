import Foundation
import IOKit.pwr_mgt
import Testing
@testable import CodevisorCoreMac

/// Host robustness (851-2375): how often a stopped capture is restarted, and the display
/// sleep assertion a live session holds.
struct ScreenSharingHostRobustnessTests {
  /// Asks `policy` at each time, in order, and returns its answers.
  private static func answers(_ times: [TimeInterval]) -> [Bool] {
    var policy = ScreenSharingCaptureRestartPolicy()
    return times.map { policy.allowsRestart(now: $0) }
  }

  @Test func aStoppedCaptureIsRestartedAFewTimesAMinuteAndThenLeftToEnd() {
    // A fourth stop inside the minute means something keeps killing the stream; once the
    // first restart is a minute old there's room for one more.
    #expect(Self.answers([100, 110, 120, 159, 160, 165]) == [true, true, true, false, true, false])
  }

  @Test func refusedRestartsDoNotUseUpTheBudget() {
    #expect(Self.answers([0, 1, 2, 3, 4, 5, 6, 60]) == [true, true, true, false, false, false, false, true])
  }

  /// The real assertion, checked through the power manager's own list of this process's
  /// assertions: present while the object lives, gone after.
  @Test func theDisplaySleepAssertionLastsAsLongAsTheSession() throws {
    let reason = "Codevisor test \(UUID().uuidString)"
    var assertion: ScreenSharingDisplaySleepAssertion? = ScreenSharingDisplaySleepAssertion(reason: reason)
    #expect(assertion?.created == true)
    #expect(Self.assertionNames().contains(reason))
    assertion = nil
    #expect(!Self.assertionNames().contains(reason))
  }

  private static func assertionNames() -> [String] {
    var byProcess: Unmanaged<CFDictionary>?
    guard IOPMCopyAssertionsByProcess(&byProcess) == kIOReturnSuccess,
      let all = byProcess?.takeRetainedValue() as? [NSNumber: [[String: Any]]]
    else { return [] }
    return (all[NSNumber(value: getpid())] ?? []).compactMap { $0[kIOPMAssertionNameKey] as? String }
  }
}
