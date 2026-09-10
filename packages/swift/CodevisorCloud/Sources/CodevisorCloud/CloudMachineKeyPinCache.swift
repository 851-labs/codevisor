import Foundation
import Observation

/// Keychain is durable storage, not part of machine lookup or view rendering.
/// Refresh prepares this snapshot before publishing machines. Explicit pin
/// changes write through so every transport sees the same trusted keys.
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

  func save(_ pins: [String: String]) throws {
    // A failed write must never turn an unpersisted key into a trusted key.
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
