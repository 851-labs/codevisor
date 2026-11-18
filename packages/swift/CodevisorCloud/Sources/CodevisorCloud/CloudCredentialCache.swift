import CodevisorClient
import Foundation
import Observation

@MainActor
@Observable
final class CloudCredentialCache {
  struct Credentials: Sendable {
    var token: String?
  }

  @ObservationIgnored private let store: any CloudCredentialStore
  @ObservationIgnored private var cached: Credentials?
  @ObservationIgnored private var writeGeneration: UInt64 = 0
  private var revision: UInt64 = 0

  init(store: any CloudCredentialStore) {
    self.store = store
  }

  var current: Credentials {
    _ = revision
    if let cached { return cached }
    let read = Self.read(from: store)
    cached = read
    return read
  }

  func load() async {
    let generation = writeGeneration
    let store = store
    let loaded = await Task.detached(priority: .userInitiated) { Self.read(from: store) }.value
    guard generation == writeGeneration else { return }
    cached = loaded
    revision &+= 1
  }

  func saveToken(_ token: String) throws {
    try store.saveToken(token)
    update { $0.token = token }
  }

  func removeToken() throws {
    try store.removeToken()
    update { $0.token = nil }
  }

  func takeLegacyServerURL() async -> URL? {
    let store = store
    let legacy = await Task.detached(priority: .userInitiated) { () -> URL? in
      guard let url = try? store.legacyServerURL() else { return nil }
      do {
        try store.removeLegacyServerURL()
      } catch {
        Log.cloud.error("Failed to clear the retired cloud server: \(String(describing: error), privacy: .public)")
      }
      return url
    }.value
    guard legacy != nil else { return nil }
    await load()
    return legacy
  }

  private func update(_ change: (inout Credentials) -> Void) {
    var updated = current
    change(&updated)
    cached = updated
    writeGeneration &+= 1
    revision &+= 1
  }

  nonisolated private static func read(from store: any CloudCredentialStore) -> Credentials {
    Credentials(token: (try? store.token()) ?? nil)
  }
}
