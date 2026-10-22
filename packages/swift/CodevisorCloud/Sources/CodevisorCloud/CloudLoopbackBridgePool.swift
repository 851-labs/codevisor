import CodevisorClient
import Foundation
import Observation

protocol CloudLoopbackBridging: AnyObject, Sendable {
  var port: UInt16? { get }
  var isStopped: Bool { get }
  func start() async throws -> UInt16
  func stop()
}

extension CloudRelayLoopbackBridge: CloudLoopbackBridging {}

@MainActor
@Observable
final class CloudLoopbackBridgePool {
  enum Health: Sendable { case healthy, listenerUnavailable, upstreamUnavailable }
  typealias Factory = (any CloudChannelTransport, @escaping @Sendable () -> Void) -> any CloudLoopbackBridging
  typealias Probe = @Sendable (URL) async -> Health

  private final class Entry {
    let key: String
    let bridge: any CloudLoopbackBridging
    var startup: Task<Bool, Never>?
    var recovery: Recovery?
    init(key: String, bridge: any CloudLoopbackBridging) { self.key = key; self.bridge = bridge }
  }
  private final class Recovery { var task: Task<Bool, Never>? }

  @ObservationIgnored private var entries: [String: Entry] = [:]
  @ObservationIgnored private let factory: Factory
  @ObservationIgnored private let probe: Probe
  @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
  private var origins: [String: URL] = [:]
  private var revisions: [String: UInt64] = [:]

  init(
    factory: @escaping Factory = { CloudRelayLoopbackBridge(endpoint: $0, onStateChange: $1) },
    probe: @escaping Probe = CloudLoopbackBridgePool.probe,
    sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }
  ) {
    self.factory = factory
    self.probe = probe
    self.sleep = sleep
  }

  var machineIds: [String] { Array(entries.keys) }
  func revision(for id: String) -> UInt64 { revisions[id, default: 0] }

  func baseURL(for id: String, key: String, endpoint: any CloudChannelTransport) -> URL? {
    let entry = ensure(id: id, key: key, endpoint: endpoint)
    _ = origins[id]
    return entry.bridge.port.flatMap { URL(string: "http://127.0.0.1:\($0)") }
  }

  private func ensure(id: String, key: String, endpoint: any CloudChannelTransport) -> Entry {
    if let entry = entries[id], entry.key == key, !entry.bridge.isStopped { return entry }
    let previous = entries.removeValue(forKey: id)
    previous?.bridge.stop()
    previous?.startup?.cancel()
    let bridge = factory(endpoint) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, let entry = self.entries[id] else { return }
        self.publish(id: id, entry: entry)
      }
    }
    let entry = Entry(key: key, bridge: bridge)
    entries[id] = entry
    let sleep = sleep
    entry.startup = Task { [weak self, weak entry] in
      let deadline = Task {
        do { try await sleep(.seconds(10)); bridge.stop() } catch {}
      }
      defer { deadline.cancel() }
      var started = false
      do { _ = try await bridge.start(); started = true } catch {
        bridge.stop()
        Log.cloud.error("Cloud loopback startup failed: \(String(describing: error), privacy: .public)")
      }
      guard let self, let entry, self.entries[id] === entry else { return false }
      self.publish(id: id, entry: entry)
      return started
    }
    return entry
  }

  private func publish(id: String, entry: Entry) {
    guard entries[id] === entry else { return }
    let origin = entry.bridge.port.flatMap { URL(string: "http://127.0.0.1:\($0)") }
    guard origins[id] != origin else { return }
    origins[id] = origin
    revisions[id, default: 0] &+= 1
  }

  func recover(for id: String, key: String, endpoint: any CloudChannelTransport) async -> Bool {
    let entry = ensure(id: id, key: key, endpoint: endpoint)
    if let task = entry.recovery?.task { return await task.value }
    let recovery = Recovery()
    let task = Task { [weak self] in
      guard let self else { return false }
      guard await entry.startup?.value == true,
        self.entries[id] === entry, !Task.isCancelled
      else { return false }
      self.publish(id: id, entry: entry)
      let health: Health
      if let url = self.origins[id] { health = await self.probe(url) } else { health = .listenerUnavailable }
      guard self.entries[id] === entry, !Task.isCancelled else { return false }
      switch health {
      case .healthy:
        self.revisions[id, default: 0] &+= 1
        return true
      case .upstreamUnavailable:
        return false
      case .listenerUnavailable:
        entry.bridge.stop()
        let replacement = self.ensure(id: id, key: key, endpoint: endpoint)
        replacement.recovery = recovery
        guard await replacement.startup?.value == true,
          self.entries[id] === replacement, !Task.isCancelled
        else { return false }
        self.publish(id: id, entry: replacement)
        guard let fresh = self.origins[id] else { return false }
        let healthy = await self.probe(fresh) == .healthy
        guard self.entries[id] === replacement, !Task.isCancelled else { return false }
        return healthy
      }
    }
    recovery.task = task
    entry.recovery = recovery
    let result = await task.value
    if entries[id]?.recovery === recovery { entries[id]?.recovery = nil }
    entry.recovery = nil
    recovery.task = nil
    return result
  }

  func remove(_ id: String) {
    let entry = entries.removeValue(forKey: id)
    entry?.bridge.stop()
    entry?.startup?.cancel()
    if origins.removeValue(forKey: id) != nil { revisions[id, default: 0] &+= 1 }
  }

  func removeAll() { for id in machineIds { remove(id) } }

  func removeAll(except kept: Set<String>) {
    for id in machineIds where !kept.contains(id) { remove(id) }
  }

  nonisolated private static func probe(_ url: URL) async -> Health {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    configuration.timeoutIntervalForResource = 5
    configuration.connectionProxyDictionary = [:]
    let session = URLSession(configuration: configuration)
    defer { session.invalidateAndCancel() }
    do {
      let (_, response) = try await session.data(from: url.appendingPathComponent("v1/discovery"))
      return (response as? HTTPURLResponse)?.statusCode == 200 ? .healthy : .upstreamUnavailable
    } catch {
      let error = error as NSError
      Log.cloud.error("Cloud loopback probe failed: \(error.domain, privacy: .public) \(error.code)")
      return error.domain == NSURLErrorDomain && error.code == NSURLErrorCannotConnectToHost
        ? .listenerUnavailable : .upstreamUnavailable
    }
  }
}
