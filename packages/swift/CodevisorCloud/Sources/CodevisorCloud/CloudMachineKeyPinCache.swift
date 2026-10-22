import CodevisorClient
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
  private(set) var changedKeys: Set<String> = []
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

  func reconcileChangedKeys(_ machines: [CloudMachine]) throws {
    let changed = try reconcile(machines)
    for deviceId in changed.subtracting(changedKeys) {
      Log.cloud.error(
        "Machine \(deviceId, privacy: .public) presented a key that conflicts with its pin; refusing relay channels until the user re-trusts it"
      )
    }
    if changedKeys != changed {
      changedKeys = changed
    }
  }

  func trust(_ machine: CloudMachine) {
    guard var pins else { return }
    pins[machine.deviceId] = machine.publicKey
    guard persist(pins) else { return }
    changedKeys.remove(machine.deviceId)
    Log.cloud.log("User re-trusted the changed key for machine \(machine.deviceId, privacy: .public)")
  }

  func removePin(deviceId: String) {
    guard var pins else { return }
    guard pins.removeValue(forKey: deviceId) != nil else { return }
    guard persist(pins) else { return }
    changedKeys.remove(deviceId)
  }

  func clear() throws {
    try save([:])
    changedKeys = []
  }

  func forgetChangedKeys() {
    changedKeys = []
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

  private func persist(_ pins: [String: String]) -> Bool {
    do {
      try save(pins)
      return true
    } catch {
      Log.cloud.error(
        "Failed to persist machine key pins: \(String(describing: error), privacy: .public)")
      return false
    }
  }
}
