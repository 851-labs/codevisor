import Foundation
import Security
import Testing

@testable import CodevisorCore

@MainActor
@Suite("Deleting device data")
struct DeviceDataWipeTests {
  @Test("Leaves nothing behind in the app container, its defaults, or its Keychain")
  func emptiesTheAppContainer() throws {
    let device = try FilledDevice()
    defer { device.discard() }

    let wipe = DeviceDataWipe(
      scope: .appContainer(home: device.home, defaults: device.defaults, defaultsDomain: device.defaultsDomain),
      keychain: device.keychain.operations
    )
    try wipe.schedule()
    wipe.erase()

    #expect(device.remainingPaths() == ["Documents", "Library", "Library/Preferences", "tmp"])
    #expect(device.defaults.persistentDomain(forName: device.defaultsDomain)?.isEmpty ?? true)
    #expect(device.keychain.isEmpty)
    #expect(!wipe.isPending)
  }

  @Test("Removes every item of a service from a Keychain that deletes one match per call, as macOS's does")
  func removesEachMatchFromTheMacKeychain() throws {
    let keychain = DeviceDataKeychain(deletesOneMatchPerCall: true)
    let service = "com.851labs.Codevisor.cloud-session"
    let credentials = KeychainCloudCredentialStore(service: service, operations: keychain.operations)
    try credentials.saveToken("session")
    try credentials.saveAppDeviceId("device")
    try credentials.saveAppSecretKey(Data([1, 2, 3]))

    KeychainWipe(scope: .services([service]), operations: keychain.operations).run()

    #expect(keychain.isEmpty)
  }

  @Test("Keeps what the scope preserves: the instance lock and the machine setup keys")
  func keepsPreservedItems() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = root.appendingPathComponent("Runtime/app-instance.lock")
    try write("lock", to: lock)
    try write("cache", to: root.appendingPathComponent("client.sqlite"))
    let domain = "codevisor.device-data.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: domain))
    defer { defaults.removePersistentDomain(forName: domain) }
    defaults.set(true, forKey: "CodevisorUsesStandaloneServer")
    defaults.set("history", forKey: "browserHistory.default")

    let scope = DeviceDataScope(
      directories: [root],
      preserved: [lock.deletingLastPathComponent()],
      defaults: defaults,
      defaultsDomain: domain,
      preservedDefaultsKeys: ["CodevisorUsesStandaloneServer"],
      keychain: .services([]),
      marker: DeviceDataScope.pendingMarker(in: root)
    )
    DeviceDataWipe(scope: scope).erase()

    #expect(FileManager.default.fileExists(atPath: lock.path))
    #expect(!FileManager.default.fileExists(atPath: root.appendingPathComponent("client.sqlite").path))
    #expect(defaults.bool(forKey: "CodevisorUsesStandaloneServer"))
    #expect(defaults.object(forKey: "browserHistory.default") == nil)
  }
}

@MainActor
private struct FilledDevice {
  let home = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
  let defaultsDomain = "codevisor.device-data.\(UUID().uuidString)"
  let defaults: UserDefaults
  let keychain = DeviceDataKeychain()

  init() throws {
    defaults = try #require(UserDefaults(suiteName: defaultsDomain))
    try fillClientDatabase()
    try fillCaches()
    try fillWebAndTemporaryFiles()
    try fillDefaultsAndKeychain()
  }

  func remainingPaths() -> [String] {
    let enumerator = FileManager.default.enumerator(at: home, includingPropertiesForKeys: nil)
    let root = home.standardizedFileURL.path + "/"
    return (enumerator?.allObjects as? [URL] ?? [])
      .map { String($0.standardizedFileURL.path.dropFirst(root.count)) }
      .sorted()
  }

  func discard() {
    try? FileManager.default.removeItem(at: home)
    defaults.removePersistentDomain(forName: defaultsDomain)
  }

  private var applicationSupport: URL { home.appendingPathComponent("Library/Application Support/Codevisor") }
  private var caches: URL { home.appendingPathComponent("Library/Caches") }

  private func fillClientDatabase() throws {
    let database = try ClientDatabase(url: applicationSupport.appendingPathComponent(ClientDatabase.fileName))
    try database.migrate(
      backupURL: applicationSupport.appendingPathComponent("MigrationRecovery/client.sqlite.pre-schema"))
    let store = ClientPersistenceStore(database: database, directory: applicationSupport)
    try store.saveData(Data("chat".utf8), forKey: "projects")
    try store.saveData(Data("draft".utf8), forKey: "composer-draft-attachment-\(UUID().uuidString.lowercased())")
    store.flushBlobWrites()
    try write("draft", to: applicationSupport.appendingPathComponent("FileDrafts/edit.json"))
  }

  private func fillCaches() throws {
    try write("page", to: caches.appendingPathComponent("Codevisor/transcripts/local_chat.json"))
    try write("png", to: caches.appendingPathComponent("Codevisor/AttachmentThumbnails-v1/thumb"))
    try write("response", to: caches.appendingPathComponent("com.851labs.Codevisor/Cache.db"))
  }

  private func fillWebAndTemporaryFiles() throws {
    try write("site", to: home.appendingPathComponent("Library/WebKit/WebsiteDataStore/profile/LocalStorage"))
    try write("cookie", to: home.appendingPathComponent("Library/Cookies/Cookies.binarycookies"))
    try write("export", to: home.appendingPathComponent("Documents/export.txt"))
    try write("preview", to: home.appendingPathComponent("tmp/com.851labs.Codevisor/CodevisorFilePreview/a.png"))
    try FileManager.default.createDirectory(
      at: home.appendingPathComponent("Library/Preferences"), withIntermediateDirectories: true)
  }

  private func fillDefaultsAndKeychain() throws {
    ScreenSharingMachinePreferences(defaults: defaults).setDynamicResolution(true, machineId: "cloud:mac")
    defaults.set(Data("visits".utf8), forKey: "browserHistory.default")
    let credentials = KeychainCloudCredentialStore(
      service: "com.851labs.Codevisor.cloud-session", operations: keychain.operations, rosterDefaults: defaults)
    try credentials.saveToken("session")
    try credentials.saveAppDeviceId("device")
    try credentials.saveAppSecretKey(Data([1, 2, 3]))
    try credentials.savePinnedMachineKeys(["cloud:mac": "key"])
    credentials.saveRoster(CachedRoster(serverURL: "https://cloud.codevisor.dev", userEmail: "a@b.c", machines: []))
    _ = keychain.operations.add([kSecClass as String: kSecClassKey, kSecAttrAccount as String: "signing"])
  }
}

private func write(_ text: String, to url: URL) throws {
  try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
  try Data(text.utf8).write(to: url)
}
