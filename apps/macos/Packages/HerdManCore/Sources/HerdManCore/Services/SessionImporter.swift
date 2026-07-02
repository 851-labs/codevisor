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
            guard let infos = try? await harnessService.listSessions(forHarnessId: harness.id) else { continue }
            result.append(contentsOf: infos.map { ImportedSession(harnessId: harness.id, info: $0) })
        }
        return result
    }
}
