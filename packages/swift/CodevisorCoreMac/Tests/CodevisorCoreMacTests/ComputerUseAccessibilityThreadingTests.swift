import Foundation
import Testing
@testable import CodevisorCoreMac

@Suite("Computer Use accessibility threading")
struct ComputerUseAccessibilityThreadingTests {
  @Test("Routes self-targeted accessibility reads to the main actor")
  func selfTargetedAccessibilityReadsUseMainActor() async {
    let currentPID = ProcessInfo.processInfo.processIdentifier
    let reachedMainActor = await Task.detached {
      computerUsePerformAccessibilityRead(targetPID: currentPID) {
        MainActor.assumeIsolated { true }
      }
    }.value

    #expect(reachedMainActor)
  }

  @Test("Keeps external accessibility reads on the bridge worker")
  func externalAccessibilityReadsStayOffMain() async {
    let externalPID = ProcessInfo.processInfo.processIdentifier &+ 1
    let stayedOffMain = await Task.detached {
      computerUsePerformAccessibilityRead(targetPID: externalPID) {
        !Thread.isMainThread
      }
    }.value

    #expect(stayedOffMain)
  }

  @Test("Treats an unknown accessibility owner as main-thread-only")
  func unknownAccessibilityOwnerUsesSafeRouting() {
    #expect(
      computerUseAccessibilityReadRequiresMainThread(
        targetPID: nil,
        currentPID: 100,
        isMainThread: false
      ))
    #expect(
      !computerUseAccessibilityReadRequiresMainThread(
        targetPID: 200,
        currentPID: 100,
        isMainThread: false
      ))
    #expect(
      !computerUseAccessibilityReadRequiresMainThread(
        targetPID: 100,
        currentPID: 100,
        isMainThread: true
      ))
  }
}
