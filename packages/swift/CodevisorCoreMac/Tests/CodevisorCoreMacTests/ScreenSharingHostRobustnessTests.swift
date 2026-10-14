import Foundation
import IOKit.pwr_mgt
import Testing
@testable import CodevisorCoreMac

struct ScreenSharingHostRobustnessTests {
  private static func answers(_ times: [TimeInterval]) -> [Bool] {
    var policy = ScreenSharingCaptureRestartPolicy()
    return times.map { policy.allowsRestart(now: $0) }
  }

  @Test func aStoppedCaptureIsRestartedAFewTimesAMinuteAndThenLeftToEnd() {
    #expect(Self.answers([100, 110, 120, 159, 160, 165]) == [true, true, true, false, true, false])
  }

  @Test func refusedRestartsDoNotUseUpTheBudget() {
    #expect(Self.answers([0, 1, 2, 3, 4, 5, 6, 60]) == [true, true, true, false, false, false, false, true])
  }

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
