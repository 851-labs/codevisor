import Foundation
import Observation

@MainActor
@Observable
final class CloudMachineKeyPinCache {
  private final class Load {
    let task: Task<[String: String], Error>
    init(task: Task<[String: String], Error>) { self.task = task }
  }

  private(set) var pins: [String: String]?
  @ObservationIgnored private(set) var generation: UInt64 = 0
  @ObservationIgnored private let store: any CloudCredentialStore
  @ObservationIgnored private let read: @Sendable () async throws -> [String: String]
  @ObservationIgnored private var loading: Load?

  init(
    store: any CloudCredentialStore,
    read: (@Sendable () async throws -> [String: String])? = nil
  ) {
    self.store = store
    self.read = read ?? { try store.pinnedMachineKeys() }
  }

  func prepare() async throws {
    guard pins == nil else { return }
    let generation = generation
    let load: Load
    if let loading {
      load = loading
    } else {
      let read = read
      load = Load(task: Task.detached { try await read() })
      loading = load
    }
    defer {
      if loading === load { loading = nil }
    }
    let loaded = try await load.task.value
    try Task.checkCancellation()
    guard self.generation == generation else { throw CancellationError() }
    if pins == nil { pins = loaded }
  }

  func reconcile(_ machines: [CloudMachine]) throws -> Set<String> {
    guard var pins = pins else { throw CancellationError() }
    var changed = Set<String>()
    var dirty = false
    for machine in machines {
      guard let pinned = pins[machine.deviceId] else {
        pins[machine.deviceId] = machine.publicKey
        dirty = true
        continue
      }
      if pinned != machine.publicKey {
        changed.insert(machine.deviceId)
      }
    }
    if dirty {
      try save(pins)
    }
    return changed
  }

  func verifiedKey(for machine: CloudMachine) -> String? {
    guard let pinned = pins?[machine.deviceId] else { return nil }
    return pinned == machine.publicKey ? machine.publicKey : nil
  }

  func save(_ pins: [String: String]) throws {
    try store.savePinnedMachineKeys(pins)
    invalidate()
    self.pins = pins
  }

  func invalidate() {
    generation &+= 1
    loading?.task.cancel()
    loading = nil
    pins = nil
  }
}
