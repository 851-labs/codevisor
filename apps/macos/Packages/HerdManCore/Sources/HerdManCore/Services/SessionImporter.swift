import Foundation
import ACPKit

/// A session discovered in a harness, tagged with which harness it belongs to.
public struct ImportedSession: Sendable, Equatable {
    public let harnessId: String
    public let info: SessionInfo

    public init(harnessId: String, info: SessionInfo) {
        self.harnessId = harnessId
        self.info = info
    }
}

/// Fetches sessions from every installed harness via the HerdMan server.
public struct SessionImporter: Sendable {
    private let harnessService: any HarnessServicing

    public init(harnessService: any HarnessServicing) {
        self.harnessService = harnessService
    }

    /// Lists sessions across all ready harnesses. Failures per harness are ignored.
    public func fetchAll() async -> [ImportedSession] {
        let harnesses = await harnessService.readyHarnesses()
        var result: [ImportedSession] = []
        for harness in harnesses {
            do {
                let infos = try await harnessService.listSessions(forHarnessId: harness.id)
                result.append(contentsOf: infos.map { ImportedSession(harnessId: harness.id, info: $0) })
            } catch {
                Log.server.error(
                    "Skipping harness \(harness.id, privacy: .public) during session import: \(String(describing: error), privacy: .public)"
                )
            }
        }
        return result
    }
}
