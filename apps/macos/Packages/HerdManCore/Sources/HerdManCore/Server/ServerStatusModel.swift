import Foundation
import Observation

@MainActor
@Observable
public final class ServerStatusModel {
    public private(set) var health: ServerHealth?
    public private(set) var info: ServerInfo?
    public private(set) var update: ServerUpdateInfo?
    public private(set) var errorMessage: String?
    public private(set) var isRefreshing = false

    private let client: any HerdManServerClienting

    public init(client: any HerdManServerClienting) {
        self.client = client
    }

    public func refresh() async {
        isRefreshing = true
        defer { isRefreshing = false }

        do {
            health = try await client.health()
            info = try await client.info()
            update = try await client.updateInfo()
            errorMessage = nil
        } catch {
            errorMessage = String(describing: error)
        }
    }

    public func issuePairingToken() async throws -> ServerPairingToken {
        try await client.issuePairingToken()
    }
}
