import Foundation
import ScreenSharingRigKit
import Testing

/// The settings sheet's sign-in edits on a Keychain VNC machine (851-2367), against an in-memory store.
struct RigVNCSignInSettingsTests {
  final class MemoryStore: RigSecretStore, @unchecked Sendable {
    private let lock = NSLock()
    private var secrets: [String: String] = [:]
    func read(_ account: String) -> String? { lock.withLock { secrets[account] } }
    func save(_ secret: String, for account: String) throws { lock.withLock { secrets[account] = secret } }
    func delete(_ account: String) { _ = lock.withLock { secrets.removeValue(forKey: account) } }
  }

  @Test func theSheetSeesTheUserNameAndWhetherAPasswordIsSaved() throws {
    let store = MemoryStore()
    #expect(RigVNCSignIn.saved(machineId: "m", store: store) == ("", false))
    try store.save(RigVNCCredential(username: "tuftlord", password: "pw").encoded, for: "m")
    #expect(RigVNCSignIn.saved(machineId: "m", store: store) == ("tuftlord", true))
  }

  @Test func forgettingRemovesTheCredential() throws {
    let store = MemoryStore()
    #expect(try !RigVNCSignIn.update(machineId: "m", userName: nil, password: .forget, store: store))
    try store.save("pw", for: "m")
    #expect(try RigVNCSignIn.update(machineId: "m", userName: nil, password: .forget, store: store))
    #expect(store.read("m") == nil)
  }

  @Test func aNewPasswordKeepsOrReplacesTheUserName() throws {
    let store = MemoryStore()
    try store.save(RigVNCCredential(username: "tuftlord", password: "old").encoded, for: "m")
    #expect(try RigVNCSignIn.update(machineId: "m", userName: nil, password: .replace("new"), store: store))
    #expect(store.read("m").map(RigVNCCredential.decode) == RigVNCCredential(username: "tuftlord", password: "new"))
    #expect(try RigVNCSignIn.update(machineId: "m", userName: "admin", password: .replace("newer"), store: store))
    #expect(store.read("m").map(RigVNCCredential.decode) == RigVNCCredential(username: "admin", password: "newer"))
  }

  @Test func aNewUserNameAloneRewritesOnlyASavedCredential() throws {
    let store = MemoryStore()
    #expect(try !RigVNCSignIn.update(machineId: "m", userName: "admin", password: .keep, store: store))
    #expect(store.read("m") == nil)
    try store.save(RigVNCCredential(username: "tuftlord", password: "pw").encoded, for: "m")
    #expect(try !RigVNCSignIn.update(machineId: "m", userName: "tuftlord", password: .keep, store: store))
    #expect(try RigVNCSignIn.update(machineId: "m", userName: "admin", password: .keep, store: store))
    #expect(store.read("m").map(RigVNCCredential.decode) == RigVNCCredential(username: "admin", password: "pw"))
  }
}
