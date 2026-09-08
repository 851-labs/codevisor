import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCloud

@MainActor
@Suite("Shared loopback recovery")
struct CloudLoopbackBridgePoolTests {
  private let endpoint = UnusedLoopbackEndpoint()

  @Test("Foreground recovery replaces a previously ready listener stuck waiting")
  func waitingAfterStartup() async throws {
    var bridges: [FakeLoopbackBridge] = []
    let pool = CloudLoopbackBridgePool(
      factory: { _, changed in
        let bridge = FakeLoopbackBridge(port: UInt16(40001 + bridges.count), changed: changed)
        bridges.append(bridge); return bridge
      }, probe: { _ in .healthy }, sleep: TestClock().sleep)
    defer { pool.removeAll() }
    #expect(await pool.recover(for: "mac", key: "key", endpoint: endpoint))
    let old = try #require(bridges.first)
    old.waitForNetwork()
    #expect(pool.baseURL(for: "mac", key: "key", endpoint: endpoint) == nil)
    #expect(await pool.recover(for: "mac", key: "key", endpoint: endpoint))
    #expect(old.isStopped)
    #expect(bridges.count == 2)
    #expect(pool.baseURL(for: "mac", key: "key", endpoint: endpoint)?.port == 40002)
  }

  @Test("Listener failure replaces its address, including before notification delivery")
  func replacesFailedListener() async throws {
    var bridges: [FakeLoopbackBridge] = []
    let clock = TestClock()
    let pool = CloudLoopbackBridgePool(
      factory: { _, changed in
        let bridge = FakeLoopbackBridge(port: UInt16(40001 + bridges.count), changed: changed)
        bridges.append(bridge); return bridge
      }, probe: { _ in .healthy }, sleep: clock.sleep)
    defer { pool.removeAll() }
    #expect(await pool.recover(for: "mac", key: "key", endpoint: endpoint))
    let first = try #require(pool.baseURL(for: "mac", key: "key", endpoint: endpoint))
    bridges[0].stop()
    #expect(pool.baseURL(for: "mac", key: "key", endpoint: endpoint) == nil)
    #expect(bridges.count == 2)
    #expect(await pool.recover(for: "mac", key: "key", endpoint: endpoint))
    let replacement = pool.baseURL(for: "mac", key: "key", endpoint: endpoint)
    #expect(replacement != first)
    bridges[0].changed()
    #expect(await pool.recover(for: "mac", key: "key", endpoint: endpoint))
    #expect(pool.baseURL(for: "mac", key: "key", endpoint: endpoint) == replacement)
    #expect(bridges.count == 2)
  }

  @Test("Concurrent panes share a probe and one refused-listener replacement")
  func coalescesRecovery() async {
    var bridges: [FakeLoopbackBridge] = []
    let release = TestSignal()
    let script = LoopbackProbeScript([.listenerUnavailable, .healthy], release: release)
    let pool = CloudLoopbackBridgePool(
      factory: { _, changed in
        let bridge = FakeLoopbackBridge(port: UInt16(40001 + bridges.count), changed: changed)
        bridges.append(bridge); return bridge
      }, probe: script.probe, sleep: TestClock().sleep)
    defer { pool.removeAll() }
    let first = Task { await pool.recover(for: "mac", key: "key", endpoint: endpoint) }
    await script.entered.wait()
    let joined = TestSignal()
    let second = Task {
      joined.signal()
      return await pool.recover(for: "mac", key: "key", endpoint: endpoint)
    }
    await joined.wait()
    release.signal()
    #expect(await first.value)
    #expect(await second.value)
    #expect(bridges.count == 2)
    #expect(await script.urls.count == 2)
  }

  @Test("Healthy foreground checks and offline machines keep the same local origin")
  func preservesHealthyOrigin() async throws {
    var bridges: [FakeLoopbackBridge] = []
    let script = LoopbackProbeScript([.healthy, .upstreamUnavailable, .healthy])
    let pool = CloudLoopbackBridgePool(
      factory: { _, changed in
        let bridge = FakeLoopbackBridge(port: 40001, changed: changed)
        bridges.append(bridge); return bridge
      }, probe: script.probe, sleep: TestClock().sleep)
    defer { pool.removeAll() }
    #expect(await pool.recover(for: "mac", key: "key", endpoint: endpoint))
    let url = try #require(pool.baseURL(for: "mac", key: "key", endpoint: endpoint))
    let revision = pool.revision(for: "mac")
    #expect(await !pool.recover(for: "mac", key: "key", endpoint: endpoint))
    #expect(pool.revision(for: "mac") == revision)
    #expect(await pool.recover(for: "mac", key: "key", endpoint: endpoint))
    #expect(pool.revision(for: "mac") > revision)
    #expect(pool.baseURL(for: "mac", key: "key", endpoint: endpoint) == url)
    #expect(bridges.count == 1)
  }

  @Test("A listener stuck starting is stopped at the bounded startup deadline")
  func startupDeadline() async throws {
    let clock = TestClock()
    var bridge: FakeLoopbackBridge?
    let pool = CloudLoopbackBridgePool(
      factory: { _, changed in
        let created = FakeLoopbackBridge(port: 40001, holdsStartup: true, changed: changed)
        bridge = created; return created
      },
      probe: { _ in
        Issue.record("An unready listener must not be probed"); return .healthy
      }, sleep: clock.sleep)
    defer { pool.removeAll() }
    let attempt = Task { await pool.recover(for: "mac", key: "key", endpoint: endpoint) }
    await clock.waitForSleep(.seconds(10))
    let starting = try #require(bridge)
    await starting.started.wait()
    clock.advance(by: .seconds(9))
    #expect(!starting.isStopped)
    clock.advance(by: .seconds(1))
    #expect(await !attempt.value)
    #expect(starting.isStopped)
    #expect(starting.port == nil)
  }

  @Test("Sign-out during a probe cannot republish an old origin")
  func discardWhileRecovering() async {
    let release = TestSignal()
    let script = LoopbackProbeScript([.healthy], release: release)
    let pool = CloudLoopbackBridgePool(
      factory: { _, changed in
        FakeLoopbackBridge(port: 40001, changed: changed)
      }, probe: script.probe, sleep: TestClock().sleep)
    let attempt = Task { await pool.recover(for: "mac", key: "key", endpoint: endpoint) }
    await script.entered.wait()
    pool.removeAll()
    let revision = pool.revision(for: "mac")
    release.signal()
    #expect(await !attempt.value)
    #expect(pool.machineIds.isEmpty)
    #expect(pool.revision(for: "mac") == revision)
  }

  @Test("Replacing a machine key during startup discards the old listener")
  func keyChangeDuringStartup() async throws {
    var bridges: [FakeLoopbackBridge] = []
    let pool = CloudLoopbackBridgePool(
      factory: { _, changed in
        let bridge = FakeLoopbackBridge(
          port: UInt16(40001 + bridges.count), holdsStartup: bridges.isEmpty, changed: changed)
        bridges.append(bridge); return bridge
      }, probe: { _ in .healthy }, sleep: TestClock().sleep)
    defer { pool.removeAll() }
    #expect(pool.baseURL(for: "mac", key: "old", endpoint: endpoint) == nil)
    let old = try #require(bridges.first)
    await old.started.wait()
    #expect(await pool.recover(for: "mac", key: "new", endpoint: endpoint))
    #expect(old.isStopped)
    let current = pool.baseURL(for: "mac", key: "new", endpoint: endpoint)
    old.ready()
    #expect(await pool.recover(for: "mac", key: "new", endpoint: endpoint))
    #expect(pool.baseURL(for: "mac", key: "new", endpoint: endpoint) == current)
    #expect(bridges.count == 2)
  }
}
