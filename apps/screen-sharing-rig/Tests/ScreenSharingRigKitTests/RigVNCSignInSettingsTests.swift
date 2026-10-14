import ScreenSharingRigKit
import Testing

struct RigVNCSignInSettingsTests {
  @Test func theSheetSeesTheUserNameAndWhetherAPasswordIsSaved() throws {
    let store = RigMemorySecretStore()
    #expect(RigVNCSignIn.saved(machineId: "m", store: store) == ("", false))
    try store.save(RigVNCCredential(username: "tuftlord", password: "pw").encoded, for: "m")
    #expect(RigVNCSignIn.saved(machineId: "m", store: store) == ("tuftlord", true))
  }

  @Test func forgettingRemovesTheCredential() throws {
    let store = RigMemorySecretStore()
    #expect(try !RigVNCSignIn.update(machineId: "m", userName: nil, password: .forget, store: store))
    try store.save("pw", for: "m")
    #expect(try RigVNCSignIn.update(machineId: "m", userName: nil, password: .forget, store: store))
    #expect(store.read("m") == nil)
  }

  @Test func aNewPasswordKeepsOrReplacesTheUserName() throws {
    let store = RigMemorySecretStore()
    try store.save(RigVNCCredential(username: "tuftlord", password: "old").encoded, for: "m")
    #expect(try RigVNCSignIn.update(machineId: "m", userName: nil, password: .replace("new"), store: store))
    #expect(store.read("m").map(RigVNCCredential.decode) == RigVNCCredential(username: "tuftlord", password: "new"))
    #expect(try RigVNCSignIn.update(machineId: "m", userName: "admin", password: .replace("newer"), store: store))
    #expect(store.read("m").map(RigVNCCredential.decode) == RigVNCCredential(username: "admin", password: "newer"))
  }

  @Test func aNewUserNameAloneRewritesOnlyASavedCredential() throws {
    let store = RigMemorySecretStore()
    #expect(try !RigVNCSignIn.update(machineId: "m", userName: "admin", password: .keep, store: store))
    #expect(store.read("m") == nil)
    try store.save(RigVNCCredential(username: "tuftlord", password: "pw").encoded, for: "m")
    #expect(try !RigVNCSignIn.update(machineId: "m", userName: "tuftlord", password: .keep, store: store))
    #expect(try RigVNCSignIn.update(machineId: "m", userName: "admin", password: .keep, store: store))
    #expect(store.read("m").map(RigVNCCredential.decode) == RigVNCCredential(username: "admin", password: "pw"))
  }
}
