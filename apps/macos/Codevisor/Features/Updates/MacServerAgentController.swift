import CodevisorCore
import CodevisorCoreMac
import Foundation
import os
import ServiceManagement

private enum MacServerAgentError: LocalizedError, Sendable {
    case requiresApproval
    case registrationDidNotEnable

    var errorDescription: String? {
        switch self {
        case .requiresApproval:
            "Codevisor's background server is disabled in System Settings."
        case .registrationDidNotEnable:
            "macOS did not enable Codevisor's background server."
        }
    }
}

/// Registers the bundled server with launchd. The service is per-user,
/// relocatable with the signed app bundle, and survives app/UI restarts.
@MainActor
final class MacServerAgentController {
    nonisolated static let plistName = "com.851labs.Codevisor.ServerAgent.plist"
    private let legacyJobs = LegacyServerJobRetirer()

    // Constructed on demand (it is cheap) so each detached closure below can
    // build its own instance instead of sending one across isolation domains.
    private nonisolated static var service: SMAppService {
        SMAppService.agent(plistName: plistName)
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
            let current = Self.service
            // This closure is reached only when no matching service is healthy.
            // Re-register an enabled-but-dead job so launchd resolves BundleProgram
            // against the app bundle that is running now, never an updater backup.
            if current.status == .enabled {
                try await current.unregister()
            }
            try current.register()
            // `register()` can return successfully while macOS leaves the
            // item awaiting approval. Treat anything short of enabled as a
            // failed managed launch so LocalCodevisorServer immediately uses
            // its app-owned fallback instead of waiting for a daemon that can
            // never start.
            switch current.status {
            case .enabled:
                return
            case .requiresApproval:
                throw MacServerAgentError.requiresApproval
            case .notRegistered, .notFound:
                throw MacServerAgentError.registrationDidNotEnable
            @unknown default:
                throw MacServerAgentError.registrationDidNotEnable
            }
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
