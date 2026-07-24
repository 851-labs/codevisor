import CodevisorCore
import Foundation
import ServiceManagement

/// Registers the bundled server with launchd. The service is per-user,
/// relocatable with the signed app bundle, and survives app/UI restarts.
@MainActor
final class MacServerAgentController {
    static let plistName = "com.851labs.Codevisor.ServerAgent.plist"

    private var service: SMAppService {
        SMAppService.agent(plistName: Self.plistName)
    }

    var managedService: LocalCodevisorManagedService {
        LocalCodevisorManagedService(
            start: { [weak self] in try await self?.ensureRegistered() },
            stop: { [weak self] in try await self?.unregister() }
        )
    }

    func ensureRegistered() async throws {
        let current = service
        // This closure is reached only when no matching service is healthy.
        // Re-register an enabled-but-dead job so launchd resolves BundleProgram
        // against the app bundle that is running now, never an updater backup.
        if current.status == .enabled {
            try await current.unregister()
        }
        try current.register()
    }

    func unregister() async throws {
        let current = service
        guard current.status == .enabled || current.status == .requiresApproval else {
            return
        }
        try await current.unregister()
    }

    func prepareForAppUpdate(localServer: LocalCodevisorServer?) async {
        if let localServer {
            _ = await localServer.prepareForAppUpdate()
        } else {
            try? await unregister()
        }
    }
}
