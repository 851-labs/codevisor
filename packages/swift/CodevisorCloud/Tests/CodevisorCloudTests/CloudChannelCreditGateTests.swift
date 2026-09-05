import Foundation
import Testing
import CodevisorTestSupport
@testable import CodevisorCloud

@Suite("CloudChannelCreditGate")
struct CloudChannelCreditGateTests {
  @Test("Sealed cost adds the framing byte only on compressed channels")
  func sealedCost() {
    #expect(CloudChannelCreditGate.sealedCost(plaintextBytes: 100, compressed: false) == 116)
    #expect(CloudChannelCreditGate.sealedCost(plaintextBytes: 100, compressed: true) == 117)
  }

  @Test("Consume proceeds when budget is available and waits when it is not")
  func consumeWaits() async throws {
    let waiting = TestSignal()
    let gate = CloudChannelCreditGate(onWait: { waiting.signal() })
    gate.add(100)
    try await gate.consume(60)  // immediate: budget in hand

    let waited = Task {
      try await gate.consume(100)  // 40 remaining: must wait for grants
      return true
    }
    await waiting.wait()
    gate.add(30)  // 70 total: still short, keeps waiting

    gate.add(30)  // 100: releases the waiter
    #expect(try await waited.value)
  }

  @Test("Failing the gate releases the waiter and rejects future consumers")
  func failure() async throws {
    let waiting = TestSignal()
    let gate = CloudChannelCreditGate(onWait: { waiting.signal() })
    let waited = Task {
      try await gate.consume(1)
    }
    await waiting.wait()
    gate.fail(CloudRelayTransportError.channelClosed(nil))
    await #expect(throws: CloudRelayTransportError.channelClosed(nil)) {
      try await waited.value
    }
    await #expect(throws: CloudRelayTransportError.channelClosed(nil)) {
      try await gate.consume(1)
    }
  }
}
