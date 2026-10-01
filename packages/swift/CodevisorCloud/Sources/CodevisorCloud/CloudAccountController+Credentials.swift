import Foundation

/// The session token and custom server as last read from or written to
/// `credentialStore`. Settings views read `serverURL`/`customServerURL`
/// several times per render and every authenticated call checks
/// `storedToken`; each used to be a Keychain query on the main thread.
/// `bootstrap` reads them once in a detached task; every write goes through
/// the store first and then the cache (`credentialWriteGeneration` keeps a
/// read that started before a write from being adopted over it).
extension CloudAccountController {
  struct StoredCredentials: Sendable {
    var token: String?
    var serverURL: URL?
  }

  /// The user-entered self-hosted server, if any (see `serverURL`).
  public var customServerURL: URL? {
    credentials.serverURL
  }

  var storedToken: String? {
    credentials.token
  }

  var credentials: StoredCredentials {
    _ = credentialRevision
    if let cachedCredentials { return cachedCredentials }
    // Only before `bootstrap` has loaded them off the main thread.
    let read = Self.readCredentials(from: credentialStore)
    cachedCredentials = read
    return read
  }

  nonisolated private static func readCredentials(from store: any CloudCredentialStore) -> StoredCredentials {
    StoredCredentials(token: (try? store.token()) ?? nil, serverURL: (try? store.serverURL()) ?? nil)
  }

  /// Reads the stored credentials in a detached task (the Keychain can
  /// block) and adopts them, unless the controller wrote newer ones
  /// meanwhile.
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
