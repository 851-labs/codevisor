import Foundation
import Observation

@MainActor
@Observable
final class CloudCredentialCache {
  struct Credentials: Sendable {
    var token: String?
    var serverURL: URL?
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

  func saveServerURL(_ url: URL?) throws {
    try store.saveServerURL(url)
    update { $0.serverURL = url }
  }

  private func update(_ change: (inout Credentials) -> Void) {
    var updated = current
    change(&updated)
    cached = updated
    writeGeneration &+= 1
    revision &+= 1
  }

  nonisolated private static func read(from store: any CloudCredentialStore) -> Credentials {
    Credentials(token: (try? store.token()) ?? nil, serverURL: (try? store.serverURL()) ?? nil)
  }
}
