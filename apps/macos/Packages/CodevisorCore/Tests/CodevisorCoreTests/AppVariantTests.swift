import Foundation
import Testing
@testable import CodevisorCore

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
}
