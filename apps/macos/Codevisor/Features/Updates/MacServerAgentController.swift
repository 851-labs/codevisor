import CodevisorCore
import CodevisorCoreMac
import Foundation
import os
import ServiceManagement

/// Registers the bundled server with launchd. The service is per-user,
/// relocatable with the signed app bundle, and survives app/UI restarts.
@MainActor
final class MacServerAgentController {
    static let plistName = "com.851labs.Codevisor.ServerAgent.plist"
    private let legacyJobs = LegacyServerJobRetirer()

    private var service: SMAppService {
        SMAppService.agent(plistName: Self.plistName)
    }

    var managedService: LocalCodevisorManagedService {
        LocalCodevisorManagedService(
            prepare: { [weak self] in try await self?.retireLegacyJobs() },
            start: { [weak self] in try await self?.ensureRegistered() },
            stop: { [weak self] in try await self?.unregister() }
        )
    }

    private func retireLegacyJobs() async throws {
        try await legacyJobs.retire()
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

    func prepareForAppUpdate(localServer: (any LocalServerControlling)?) async -> Bool {
        do {
            try await retireLegacyJobs()
        } catch {
            Log.server.error(
                "Legacy server cleanup failed before update: \(String(describing: error), privacy: .public)"
            )
            return false
        }
        if let localServer {
            return await localServer.prepareForAppUpdate()
        } else {
            do {
                try await unregister()
                return true
            } catch {
                Log.server.error(
                    "ServerAgent unregister failed before update: \(String(describing: error), privacy: .public)"
                )
                return false
            }
        }
    }
}
