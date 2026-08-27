import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

// MARK: - Machine-scoped MCP actions
extension McpMachinePane {
    func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            servers = try await client.listMcpServers()
            browserConfiguration = try? await client.browserUseConfiguration()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        // Permission-derived toggle state must be current whenever the pane
        // loads; remote machines have no local probes to refresh.
        if machine.isLocal { permissions?.refresh() }
        // Native discovery is best-effort: older servers (404/501) or scan
        // failures simply hide those rows instead of surfacing an error.
        nativeScan = try? await client.listNativeMcps()
    }

    /// True when the per-machine overlay switches this server off HERE.
    func machineDisabled(_ server: ServerMcpServer) -> Bool {
        guard let key = environment.machines.syncKey(forMachineId: machine.id) else { return false }
        return McpFleet.isDisabled(environment.configSync, machineId: key, name: server.name)
    }

    /// The row's effective view of the server: a machine-disabled server
    /// reads as off no matter what the fleet definition says.
    func displayServer(_ server: ServerMcpServer) -> ServerMcpServer {
        guard machineDisabled(server) else { return server }
        var copy = server
        copy.enabled = false
        copy.connectionState = "disconnected"
        return copy
    }

    /// The toggle's one meaning: available on THIS machine. Off writes the
    /// per-machine overlay only. On clears the overlay — and if the fleet
    /// definition itself was off, re-enables it for the fleet.
    func setEnabled(_ server: ServerMcpServer, enabled: Bool) async {
        if server.kind == "computerUse", enabled, machine.isLocal {
            permissions?.refresh()
            // The toggle is disabled while permissions are missing; this
            // guard just keeps a stale press from half-enabling.
            guard permissions?.allGranted == true else { return }
            environment.settings.setPermissionsSetupSkipped(false)
            environment.settings.setPermissionsReviewedVersion(AppUpdateModel.bundleVersion())
        }
        guard let key = environment.machines.syncKey(forMachineId: machine.id) else {
            errorMessage = "This machine hasn't reported its identity yet."
            return
        }
        McpFleet.setDisabled(
            environment.configSync,
            machineId: key,
            name: server.name,
            disabled: !enabled
        )
        guard enabled, !server.enabled else { return }
        do {
            let updated = try await client.setMcpServerEnabled(id: server.id, enabled: true)
            replace(server, with: updated)
            if updated.connectionState == "needsSetup" {
                for _ in 0..<90 {
                    try? await Task.sleep(for: .seconds(2))
                    let refreshed = try await client.listMcpServers()
                    guard let current = refreshed.first(where: { $0.id == server.id }) else { break }
                    replace(updated, with: current)
                    if current.connectionState != "needsSetup" { break }
                }
            }
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    func remove(_ server: ServerMcpServer) async {
        do {
            try await client.removeMcpServer(id: server.id)
            servers.removeAll { $0.id == server.id }
            serverPendingRemoval = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    func beginOAuth(_ server: ServerMcpServer) async throws {
        let flow = try await client.startMcpOAuth(id: server.id)
        guard let url = URL(string: flow.authorizationUrl) else { return }
        NSWorkspace.shared.open(url)
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(2))
            await reload()
            if servers.first(where: { $0.id == server.id })?.connectionState == "connected" { break }
        }
    }

    func setPreferredBrowser(_ preference: String) async {
        do {
            browserConfiguration = try await client.setPreferredBrowser(preference)
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    func installBrowserExtension() async {
        do {
            browserConfiguration = try await client.installDevelopmentBrowserExtension()
            for _ in 0..<120 {
                try? await Task.sleep(for: .seconds(1))
                let refreshed = try await client.browserUseConfiguration()
                browserConfiguration = refreshed
                if refreshed.chromeConnected { break }
            }
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    func removeNativeServer(_ server: ServerNativeMcpServer) async {
        do {
            let result = try await client.removeNativeMcp(
                harnessId: server.harnessId,
                serverName: server.serverName
            )
            nativeScan = result.scan
            lastNativeRemoval = result.removal
            nativeActionError = nil
        } catch {
            nativeActionError = ErrorReporter.userFacingMessage(for: error)
        }
    }

    func undoNativeRemoval(_ removal: ServerNativeMcpRemoval) async {
        do {
            nativeScan = try await client.restoreNativeMcpRemoval(id: removal.id)
            lastNativeRemoval = nil
            nativeActionError = nil
        } catch {
            nativeActionError = ErrorReporter.userFacingMessage(for: error)
        }
    }

    func setNativeEnabled(_ server: ServerNativeMcpServer, enabled: Bool) async {
        do {
            nativeScan = try await client.setNativeMcpEnabled(
                harnessId: server.harnessId,
                serverName: server.serverName,
                enabled: enabled
            )
            nativeActionError = nil
        } catch {
            nativeActionError = ErrorReporter.userFacingMessage(for: error)
        }
    }

    func importIdentities(_ identities: [String]) async {
        importingIdentities.formUnion(identities)
        defer { importingIdentities.subtract(identities) }
        do {
            let result = try await client.importNativeMcps(identities: identities)
            nativeScan = result.scan
            importFeedback = feedback(for: result.outcomes)
            // The managed list changed too — refresh it (not the native scan,
            // which the result already replaced).
            servers = try await client.listMcpServers()
        } catch {
            importFeedback = ErrorReporter.userFacingMessage(for: error)
        }
    }

    /// Fold a batch's outcomes into one footer line: failures first, then
    /// warnings, silence when everything just worked.
    func feedback(for outcomes: [ServerNativeMcpImportOutcome]) -> String? {
        var parts: [String] = []
        for outcome in outcomes {
            if outcome.status == "failed", let detail = outcome.detail {
                parts.append("\(outcome.identity): \(detail)")
            }
            parts.append(contentsOf: outcome.warnings)
        }
        let imported = outcomes.filter { $0.status == "imported" }.count
        if parts.isEmpty {
            return imported > 0
                ? "Imported \(imported) server\(imported == 1 ? "" : "s")."
                : nil
        }
        return parts.joined(separator: " · ")
    }
}
