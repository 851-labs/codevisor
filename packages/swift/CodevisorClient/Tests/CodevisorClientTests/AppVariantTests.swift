import Foundation
import Testing
import CodevisorProtocol

@testable import CodevisorClient

@Suite("CodevisorAppVariant")
struct AppVariantTests {
  /// The HerdMan → Codevisor rename changed the Application Support folder
  /// name while the app updated in place, orphaning all file-backed
  /// preferences. The rescue copies legacy files across exactly once.
  @Test("Legacy HerdMan files are copied over without overwriting")
  func legacyApplicationSupportMigration() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("codevisor-migration-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: root) }
    let legacy = root.appendingPathComponent("HerdMan")
    let destination = root.appendingPathComponent("Codevisor")
    try fileManager.createDirectory(at: legacy, withIntermediateDirectories: true)
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

    // Orphaned prefs that only exist in the legacy folder are rescued.
    try Data(#"{"lastHarnessId":"claude-code"}"#.utf8)
      .write(to: legacy.appendingPathComponent("composer-defaults.json"))
    // Files the new install already wrote are never overwritten.
    try Data("current".utf8).write(to: destination.appendingPathComponent("settings.json"))
    try Data("stale".utf8).write(to: legacy.appendingPathComponent("settings.json"))
    // Non-JSON artifacts stay behind.
    try Data("log".utf8).write(to: legacy.appendingPathComponent("debug.log"))

    CodevisorAppVariant.migrateLegacyApplicationSupport(
      from: legacy, to: destination, fileManager: fileManager
    )

    let copied = try Data(contentsOf: destination.appendingPathComponent("composer-defaults.json"))
    #expect(String(decoding: copied, as: UTF8.self) == #"{"lastHarnessId":"claude-code"}"#)
    let kept = try Data(contentsOf: destination.appendingPathComponent("settings.json"))
    #expect(String(decoding: kept, as: UTF8.self) == "current")
    #expect(!fileManager.fileExists(atPath: destination.appendingPathComponent("debug.log").path))
    // The legacy folder survives as a backup.
    #expect(fileManager.fileExists(atPath: legacy.appendingPathComponent("composer-defaults.json").path))
  }

  @Test("Parses the dev cloud configuration from launch environment")
  func developmentCloudParsing() {
    let full = CodevisorAppVariant.developmentCloud(from: [
      "CODEVISOR_DEV_CLOUD_URL": "http://127.0.0.1:8787"
    ])
    #expect(full == CodevisorAppVariant.DevelopmentCloud(url: URL(string: "http://127.0.0.1:8787")!))

    // No URL (or a blank one) means no dev cloud at all.
    #expect(CodevisorAppVariant.developmentCloud(from: [:]) == nil)
    #expect(CodevisorAppVariant.developmentCloud(from: ["CODEVISOR_DEV_CLOUD_URL": ""]) == nil)
  }

  @Test("Migration is a no-op when there is no legacy folder")
  func migrationWithoutLegacyFolder() throws {
    let fileManager = FileManager.default
    let root = fileManager.temporaryDirectory
      .appendingPathComponent("codevisor-migration-\(UUID().uuidString)")
    defer { try? fileManager.removeItem(at: root) }
    let destination = root.appendingPathComponent("Codevisor")
    try fileManager.createDirectory(at: destination, withIntermediateDirectories: true)

    CodevisorAppVariant.migrateLegacyApplicationSupport(
      from: root.appendingPathComponent("HerdMan"), to: destination, fileManager: fileManager
    )

    #expect(try fileManager.contentsOfDirectory(atPath: destination.path).isEmpty)
  }

  @Test("Recovers dev instance configuration when relaunched outside the runner")
  func resolvesDevLaunchEnvironment() {
    let configured = [
      "CODEVISOR_DEV_INSTANCE_ID": "lingonberry-abc",
      "CODEVISOR_DEV_DATA_DIR": "/tmp/instance",
      "HERDMAN_DEV_PORT": "1234",
      "PATH": "/usr/bin",
    ]

    // A configured launch passes through and refreshes the stash with
    // only the instance variables.
    let fromRunner = CodevisorAppVariant.resolvedDevelopmentEnvironment(
      live: configured,
      stashed: ["CODEVISOR_DEV_DATA_DIR": "/tmp/old"]
    )
    #expect(fromRunner.environment == configured)
    #expect(
      fromRunner.stash == [
        "CODEVISOR_DEV_INSTANCE_ID": "lingonberry-abc",
        "CODEVISOR_DEV_DATA_DIR": "/tmp/instance",
        "HERDMAN_DEV_PORT": "1234",
      ])

    // macOS "Quit & Reopen" launches bare: the stashed configuration is
    // restored so the app keeps pointing at the same instance's data.
    let reopened = CodevisorAppVariant.resolvedDevelopmentEnvironment(
      live: ["PATH": "/usr/bin"],
      stashed: fromRunner.stash
    )
    #expect(reopened.environment["CODEVISOR_DEV_INSTANCE_ID"] == "lingonberry-abc")
    #expect(reopened.environment["CODEVISOR_DEV_DATA_DIR"] == "/tmp/instance")
    #expect(reopened.environment["PATH"] == "/usr/bin")
    #expect(reopened.stash == nil)

    // Nothing stashed and nothing configured: plain passthrough.
    let bare = CodevisorAppVariant.resolvedDevelopmentEnvironment(
      live: ["PATH": "/usr/bin"],
      stashed: nil
    )
    #expect(bare.environment == ["PATH": "/usr/bin"])
    #expect(bare.stash == nil)
  }
}
