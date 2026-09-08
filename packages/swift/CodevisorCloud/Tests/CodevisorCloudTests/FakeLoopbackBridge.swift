import ACPKit
import CodevisorTestSupport
import Foundation
@testable import CodevisorCloud

final class FakeLoopbackBridge: CloudLoopbackBridging, @unchecked Sendable {
  private let lock = NSLock()
  private var listeningPort: UInt16?
  private var stopped = false
  private var pending: CheckedContinuation<UInt16, any Error>?
  let readyPort: UInt16
  let holdsStartup: Bool
  let changed: @Sendable () -> Void
  let started = TestSignal()

  init(port: UInt16, holdsStartup: Bool = false, changed: @escaping @Sendable () -> Void) {
    readyPort = port; self.holdsStartup = holdsStartup; self.changed = changed
  }
  var port: UInt16? { lock.withLock { listeningPort } }
  var isStopped: Bool { lock.withLock { stopped } }
  func start() async throws -> UInt16 {
    try await withCheckedThrowingContinuation { continuation in
      let accepted = lock.withLock {
        guard !stopped else { return false }
        pending = continuation
        return true
      }
      if !accepted { continuation.resume(throwing: URLError(.cancelled)) } else if !holdsStartup { ready() }
      started.signal()
    }
  }
  func ready() {
    let result = lock.withLock { () -> CheckedContinuation<UInt16, any Error>? in
      guard !stopped else { return nil }
      listeningPort = readyPort
      let result = pending; pending = nil
      return result
    }
    result?.resume(returning: readyPort)
    changed()
  }
  func stop() {
    let result = lock.withLock { () -> CheckedContinuation<UInt16, any Error>? in
      stopped = true; listeningPort = nil
      let result = pending; pending = nil
      return result
    }
    result?.resume(throwing: URLError(.cancelled))
    changed()
  }
  func waitForNetwork() {
    lock.withLock { listeningPort = nil }
    changed()
  }
}

actor LoopbackProbeScript {
  var results: [CloudLoopbackBridgePool.Health]
  var urls: [URL] = []
  let entered = TestSignal()
  let release: TestSignal?
  init(_ results: [CloudLoopbackBridgePool.Health], release: TestSignal? = nil) {
    self.results = results; self.release = release
  }
  func probe(_ url: URL) async -> CloudLoopbackBridgePool.Health {
    urls.append(url)
    let result = results.removeFirst()
    entered.signal()
    if let release { await release.wait() }
    return result
  }
}

struct UnusedLoopbackEndpoint: CloudChannelTransport {
  let machineDeviceId = "fixture"
  func openChannel(
    channelType: String, params: JSONValue?, compressed: Bool,
    onMessage: @escaping @Sendable (Data) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel { throw URLError(.unsupportedURL) }
  func openFlowControlledChannel(
    channelType: String, params: JSONValue?, compressed: Bool,
    onMessage: @escaping @Sendable (Data, Int) -> Void,
    onCredit: @escaping @Sendable (Int) -> Void,
    onClosed: @escaping @Sendable (CloudChannelCloseReason?) -> Void
  ) async throws -> CloudRelayChannel { throw URLError(.unsupportedURL) }
}
