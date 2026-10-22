import Testing

@testable import CodevisorCore

struct RetryBackoffTests {
  @Test("Machine retries double after each failure up to a one-minute ceiling")
  func doublesToCeiling() {
    let multipliers = (1...8).map { RetryBackoff.multiplier(afterFailures: $0) }

    #expect(multipliers == [2, 4, 8, 16, 32, 60, 60, 60])
  }
}
