import CodevisorCore
import CodevisorCoreMac
import Foundation
import os
import ServiceManagement

/// Registers the bundled server with launchd. The service is per-user,
/// relocatable with the signed app bundle, and survives app/UI restarts.
@MainActor
final class MacServerAgentController {
    static let plistName = "com.codevisor.macos.ServerAgent.plist"
    /// The pre-team-migration agent (851labs identity). Its plist still ships
    /// in the bundle solely so SMAppService can cleanly unregister the
    /// registration left behind by pre-migration installs — unregistering
    /// requires the service definition to exist. Remove the plist and this
    /// path once the fleet has migrated.
    static let legacyPlistName = "com.851labs.Codevisor.ServerAgent.plist"
    private let legacyJobs = LegacyServerJobRetirer()

    // Constructed on demand (it is cheap) so each detached closure below can
    // build its own instance instead of sending one across isolation domains.
    private nonisolated static var service: SMAppService {
        SMAppService.agent(plistName: plistName)
    }

    private nonisolated static var legacyService: SMAppService {
        SMAppService.agent(plistName: legacyPlistName)
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
        // SMAppService.status/register/unregister are synchronous XPC round
        // trips to launchd/smd, so keep them off the main actor.
        try await Task.detached {
            // A pre-migration install registered the agent under the 851labs
            // plist; drop that registration before the renamed agent takes
            // ownership, or launchd would bootstrap both at next login.
            let legacy = Self.legacyService
            if legacy.status == .enabled || legacy.status == .requiresApproval {
                try? await legacy.unregister()
            }
            let current = Self.service
            // This closure is reached only when no matching service is healthy.
            // Re-register an enabled-but-dead job so launchd resolves BundleProgram
            // against the app bundle that is running now, never an updater backup.
            if current.status == .enabled {
                try await current.unregister()
            }
            try current.register()
        }.value
    }

    func unregister() async throws {
        try await Task.detached {
            let current = Self.service
            guard current.status == .enabled || current.status == .requiresApproval else {
                return
            }
            try await current.unregister()
        }.value
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
