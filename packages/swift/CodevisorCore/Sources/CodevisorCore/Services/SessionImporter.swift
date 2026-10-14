import Foundation
import ACPKit

public struct ImportedSession: Sendable, Equatable {
  public let harnessId: String
  public let info: SessionInfo

  public init(harnessId: String, info: SessionInfo) {
    self.harnessId = harnessId
    self.info = info
  }
}

public struct SessionImporter: Sendable {
  private let harnessService: any HarnessServicing

  public init(harnessService: any HarnessServicing) {
    self.harnessService = harnessService
  }

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
