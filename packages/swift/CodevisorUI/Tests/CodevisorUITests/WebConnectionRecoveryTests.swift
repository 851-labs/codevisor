import Foundation
import Testing
@testable import CodevisorUI

@Suite("Safe page connection recovery")
struct WebConnectionRecoveryTests {
  @Test("Only uncommitted read-only loads qualify for automatic recovery")
  func safeRequests() {
    let error = URLError(.cannotConnectToHost)
    #expect(WebConnectionRecovery.accepts(error, method: "GET", provisional: true))
    #expect(WebConnectionRecovery.accepts(error, method: "HEAD", provisional: true))
    #expect(!WebConnectionRecovery.accepts(error, method: "POST", provisional: true))
    #expect(!WebConnectionRecovery.accepts(error, method: "GET", provisional: false))
    #expect(!WebConnectionRecovery.accepts(URLError(.cancelled), method: "GET", provisional: true))
    #expect(!WebConnectionRecovery.accepts(URLError(.serverCertificateUntrusted), method: "GET", provisional: true))
    #expect(!WebConnectionRecovery.accepts(NSError(domain: "Other", code: -1004), method: "GET", provisional: true))
  }

  @Test("A persistent failure retries once until a user retry or a successful navigation")
  func boundedRetry() {
    var recovery = WebConnectionRecovery()
    let first = recovery.claimRetry()
    #expect(first)
    #expect(!recovery.canRetry)
    let repeated = recovery.claimRetry()
    #expect(!repeated)
    recovery.reset()
    let manual = recovery.claimRetry()
    #expect(manual)
  }
}
