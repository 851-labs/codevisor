import Testing

@testable import ScreenSharingRigKit

struct RigReconnectPolicyTests {
  @Test func doublesFromOneSecondAndCapsAtTen() {
    var policy = RigReconnectPolicy()
    #expect(policy.failed() == 1)
    #expect(policy.failed() == 2)
    #expect(policy.failed() == 4)
    #expect(policy.failed() == 8)
    #expect(policy.failed() == 10)
    #expect(policy.failed() == 10)
    #expect(policy.consecutiveFailures == 6)
  }

  @Test func successResetsSoADroppedSessionRetriesQuickly() {
    var policy = RigReconnectPolicy()
    _ = policy.failed()
    _ = policy.failed()
    policy.succeeded()
    #expect(policy.consecutiveFailures == 0)
    #expect(policy.failed() == 1)
  }
}
