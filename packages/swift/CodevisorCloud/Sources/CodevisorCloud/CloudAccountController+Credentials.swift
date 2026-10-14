import Foundation

extension CloudAccountController {
  struct StoredCredentials: Sendable {
    var token: String?
    var serverURL: URL?
  }

  public var customServerURL: URL? {
    credentials.serverURL
  }

  var storedToken: String? {
    credentials.token
  }

  var credentials: StoredCredentials {
    _ = credentialRevision
    if let cachedCredentials { return cachedCredentials }
    let read = Self.readCredentials(from: credentialStore)
    cachedCredentials = read
    return read
  }

  nonisolated private static func readCredentials(from store: any CloudCredentialStore) -> StoredCredentials {
    StoredCredentials(token: (try? store.token()) ?? nil, serverURL: (try? store.serverURL()) ?? nil)
  }

  func loadCredentials() async {
    let generation = credentialWriteGeneration
    let store = credentialStore
    let loaded = await Task.detached(priority: .userInitiated) { Self.readCredentials(from: store) }.value
    guard generation == credentialWriteGeneration else { return }
    cachedCredentials = loaded
    credentialRevision &+= 1
  }

  func saveStoredToken(_ token: String) throws {
    try credentialStore.saveToken(token)
    updateCredentials { $0.token = token }
  }

  func removeStoredToken() throws {
    try credentialStore.removeToken()
    updateCredentials { $0.token = nil }
  }

  func saveCustomServerURL(_ url: URL?) throws {
    try credentialStore.saveServerURL(url)
    updateCredentials { $0.serverURL = url }
  }

  private func updateCredentials(_ change: (inout StoredCredentials) -> Void) {
    var updated = credentials
    change(&updated)
    cachedCredentials = updated
    credentialWriteGeneration &+= 1
    credentialRevision &+= 1
  }
}
