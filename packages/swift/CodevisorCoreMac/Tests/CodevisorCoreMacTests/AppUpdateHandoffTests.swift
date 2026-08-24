import Foundation
import Testing

@testable import CodevisorCoreMac

@Suite("AppUpdateHandoff")
struct AppUpdateHandoffTests {
    private func temporaryURL(_ name: String) -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("app-update-handoff-\(UUID().uuidString)-\(name)")
    }

    @Test("Channel writes mirror the alpha preference")
    func channelWrites() throws {
        let url = temporaryURL("channel")
        defer { try? FileManager.default.removeItem(at: url) }

        AppUpdateHandoff.writeChannel(allowsAlpha: true, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "alpha\n")
        AppUpdateHandoff.writeChannel(allowsAlpha: false, to: url)
        #expect(try String(contentsOf: url, encoding: .utf8) == "stable\n")
    }

    @Test("Status reports carry state, reason, target, and timestamp")
    func statusWrites() throws {
        let url = temporaryURL("status.json")
        defer { try? FileManager.default.removeItem(at: url) }

        let date = Date(timeIntervalSince1970: 1_756_000_000)
        AppUpdateHandoff.writeStatus(
            state: "failed",
            message: "Sparkle: no signature",
            targetVersion: "0.2.0",
            at: date,
            to: url
        )

        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(payload["state"] as? String == "failed")
        #expect(payload["message"] as? String == "Sparkle: no signature")
        #expect(payload["targetVersion"] as? String == "0.2.0")
        #expect(payload["at"] as? String == ISO8601DateFormatter().string(from: date))
    }

    @Test("Optional fields are omitted, not encoded as null")
    func statusOmitsAbsentFields() throws {
        let url = temporaryURL("status.json")
        defer { try? FileManager.default.removeItem(at: url) }

        AppUpdateHandoff.writeStatus(state: "installing", to: url)

        let payload = try #require(
            try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        )
        #expect(payload["state"] as? String == "installing")
        #expect(payload["at"] is String)
        #expect(payload.keys.contains("message") == false)
        #expect(payload.keys.contains("targetVersion") == false)
    }

    @Test("Clearing removes a previous session's report")
    func statusClears() {
        let url = temporaryURL("status.json")

        AppUpdateHandoff.writeStatus(state: "installing", to: url)
        #expect(FileManager.default.fileExists(atPath: url.path))
        AppUpdateHandoff.clearStatus(at: url)
        #expect(!FileManager.default.fileExists(atPath: url.path))
    }
}
