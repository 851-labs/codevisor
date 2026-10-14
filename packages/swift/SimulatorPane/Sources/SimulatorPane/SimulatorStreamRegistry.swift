import CodevisorClient
import CodevisorCloud
import CoreGraphics
import Foundation
import ScreenSharing

struct SimulatorStreamSponsor {
  let workspaceId: UUID
  let paneId: UUID
  let client: any CodevisorServerClienting
  let openTunnel: (@MainActor () async -> CloudTunnelMediaRoute?)?
}

@MainActor
protocol SimulatorSharedConnection: SimulatorConnection {
  func rebind(to sponsor: SimulatorStreamSponsor)
}

@MainActor
final class SimulatorStreamRegistry {
  static let shared = SimulatorStreamRegistry { udid, sponsor in
    SimulatorStreamConnection(udid: udid, sponsor: sponsor)
  }

  struct Key: Hashable {
    let machineId: String
    let udid: String
  }

  final class Entry {
    let connection: any SimulatorSharedConnection
    fileprivate(set) var sponsor: SimulatorStreamSponsor
    fileprivate var handles: [SimulatorStreamHandle] = []
    private var fanOut: SimulatorFrameFanOut?

    fileprivate init(connection: any SimulatorSharedConnection, sponsor: SimulatorStreamSponsor) {
      self.connection = connection
      self.sponsor = sponsor
    }

    func output(for id: UUID, from source: ScreenSharingFrameMailbox) -> ScreenSharingFrameMailbox {
      let fanOut = self.fanOut.flatMap { $0.source === source ? $0 : nil } ?? SimulatorFrameFanOut(source: source)
      self.fanOut = fanOut
      return fanOut.output(for: id)
    }

    fileprivate func removeOutput(for id: UUID) { fanOut?.remove(id) }
  }

  private let makeConnection:
    @MainActor (_ udid: String, _ sponsor: SimulatorStreamSponsor) -> any SimulatorSharedConnection
  private var entries: [Key: Entry] = [:]

  init(
    makeConnection:
      @escaping @MainActor (_ udid: String, _ sponsor: SimulatorStreamSponsor) ->
      any SimulatorSharedConnection
  ) {
    self.makeConnection = makeConnection
  }

  func handle(machineId: String, udid: String, sponsor: SimulatorStreamSponsor) -> SimulatorStreamHandle {
    SimulatorStreamHandle(registry: self, key: Key(machineId: machineId, udid: udid), sponsor: sponsor)
  }

  func retire(paneId: UUID) {
    for entry in entries.values where entry.sponsor.paneId == paneId {
      guard let next = entry.handles.first(where: { $0.sponsor.paneId != paneId }) else { continue }
      entry.sponsor = next.sponsor
      entry.connection.rebind(to: next.sponsor)
    }
  }

  fileprivate func acquire(_ handle: SimulatorStreamHandle) -> Entry {
    if let entry = entries[handle.key] {
      entry.handles.append(handle)
      if case .failed = entry.connection.phase {
        entry.connection.stop()
        entry.connection.start()
      }
      return entry
    }
    let entry = Entry(connection: makeConnection(handle.key.udid, handle.sponsor), sponsor: handle.sponsor)
    entry.handles = [handle]
    entries[handle.key] = entry
    entry.connection.start()
    return entry
  }

  fileprivate func release(_ handle: SimulatorStreamHandle) {
    guard let entry = entries[handle.key] else { return }
    entry.handles.removeAll { $0 === handle }
    entry.removeOutput(for: handle.id)
    guard entry.handles.isEmpty else { return }
    entries[handle.key] = nil
    entry.connection.stop()
  }
}

@MainActor
final class SimulatorStreamHandle: SimulatorConnection {
  let id = UUID()
  let key: SimulatorStreamRegistry.Key
  let sponsor: SimulatorStreamSponsor
  private let registry: SimulatorStreamRegistry
  private var entry: SimulatorStreamRegistry.Entry?

  fileprivate init(registry: SimulatorStreamRegistry, key: SimulatorStreamRegistry.Key, sponsor: SimulatorStreamSponsor)
  {
    self.registry = registry
    self.key = key
    self.sponsor = sponsor
  }

  var phase: SimulatorConnectionPhase { entry?.connection.phase ?? .connecting }
  var state: ScreenSharingSimulatorState? { entry?.connection.state }
  var frameSize: CGSize? { entry?.connection.frameSize }

  var source: SimulatorScreenSource? {
    guard let entry else { return nil }
    guard case .video(let mailbox, let metrics) = entry.connection.source else { return entry.connection.source }
    return .video(entry.output(for: id, from: mailbox), metrics)
  }

  func start() {
    guard entry == nil else { return }
    entry = registry.acquire(self)
  }

  func stop() {
    guard entry != nil else { return }
    entry = nil
    registry.release(self)
  }

  @discardableResult
  func send(_ message: ScreenSharingSimulatorMessage) -> Bool { entry?.connection.send(message) ?? false }

  func presented(frameSize: CGSize) { entry?.connection.presented(frameSize: frameSize) }
}

final class SimulatorFrameFanOut: @unchecked Sendable {
  let source: ScreenSharingFrameMailbox
  private let lock = NSLock()
  private var last: ScreenSharingVideoFrame?
  private var outputs: [UUID: ScreenSharingFrameMailbox] = [:]

  init(source: ScreenSharingFrameMailbox) {
    self.source = source
    source.onFrameAvailable { [weak self] in self?.forward() }
  }

  deinit { source.onFrameAvailable(nil) }

  func output(for id: UUID) -> ScreenSharingFrameMailbox {
    lock.withLock {
      if let existing = outputs[id] { return existing }
      let output = ScreenSharingFrameMailbox()
      if let last { output.put(last) }
      outputs[id] = output
      return output
    }
  }

  func remove(_ id: UUID) {
    lock.withLock { outputs[id] = nil }
  }

  private func forward() {
    guard let frame = source.take() else { return }
    let targets = lock.withLock {
      last = frame
      return Array(outputs.values)
    }
    for target in targets { target.put(frame) }
  }
}
