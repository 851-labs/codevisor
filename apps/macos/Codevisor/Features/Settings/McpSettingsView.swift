import AppKit
import CodevisorCore
import CodevisorCoreMac
import SwiftUI
import CodevisorUI

struct McpSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @Environment(\.settingsMachineId) private var settingsMachineId
    @State private var servers: [ServerMcpServer] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingAdd = false
    @State private var selectedServer: ServerMcpServer?
    @State private var editingServer: ServerMcpServer?
    @State private var serverPendingRemoval: ServerMcpServer?
    /// Native discovery is additive: nil (older server or scan failure) hides
    /// the sections entirely rather than blocking the managed list.
    @State private var nativeScan: ServerNativeMcpScan?
    @State private var showsNativeInstalled = false
    @State private var selectedNativeServer: ServerNativeMcpServer?
    /// Identities currently being imported (per-row spinners) and the last
    /// batch's failures/warnings for the section footer.
    @State private var importingIdentities: Set<String> = []
    @State private var importFeedback: String?
    /// Native destructive-op state: pending confirmation, this session's
    /// most recent removal (for Undo), and any failure message.
    @State private var nativeServerPendingRemoval: ServerNativeMcpServer?
    @State private var lastNativeRemoval: ServerNativeMcpRemoval?
    @State private var nativeActionError: String?
    @State private var expandedNativeHarnesses: Set<String> = []
    @State private var browserConfiguration: ServerBrowserUseConfiguration?
    /// Computer Use permission status for the inline setup under its row.
    /// While either permission is missing, the setup rows stay visible there
    /// and the enable toggle is disabled; granting both collapses the rows
    /// and unlocks the toggle.
    @State private var computerPermissions = ComputerUsePermissionsModel(
        probes: AppPreview.isRunning ? .granted : .live
    )

    /// The machine whose MCP servers this pane manages.
    private var serverId: String {
        settingsMachineId ?? environment.machines.selectedMachineId
    }

    private var client: any CodevisorServerClienting {
        environment.machines.client(for: serverId)
    }

    var body: some View {
        content
            .background {
                if !theme.isSystem { theme.windowBackground }
            }
            .task(id: serverId) { await reload() }
            .sheet(isPresented: $showingAdd) {
                McpServerEditorSheet(initialServer: nil) { values in
                    let created = try await client.createMcpServer(values.createBody)
                    servers.append(created)
                    servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    if created.authType == "oauth" {
                        Task {
                            do { try await beginOAuth(created) } catch {
                                errorMessage = ErrorReporter.userFacingMessage(for: error)
                            }
                        }
                    }
                }
            }
            .sheet(item: $editingServer) { server in
                McpServerEditorSheet(initialServer: server) { values in
                    let updated = try await client.updateMcpServer(
                        id: server.id,
                        request: values.updateBody
                    )
                    replace(server, with: updated)
                    if updated.authType == "oauth" && updated.connectionState == "needsAuthorization" {
                        Task {
                            do { try await beginOAuth(updated) } catch {
                                errorMessage = ErrorReporter.userFacingMessage(for: error)
                            }
                        }
                    }
                }
            }
            .sheet(item: $selectedServer) { server in
                McpServerDetailSheet(server: server) {
                    await reload()
                }
                .environment(environment)
            }
            .sheet(item: $selectedNativeServer) { server in
                NativeMcpDetailSheet(server: server)
            }
            .confirmationDialog(
                "Remove \(nativeServerPendingRemoval?.serverName ?? "server") from \(nativeServerPendingRemoval?.harnessName ?? "harness")?",
                isPresented: Binding(
                    get: { nativeServerPendingRemoval != nil },
                    set: { if !$0 { nativeServerPendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove from \(nativeServerPendingRemoval?.harnessName ?? "Harness")", role: .destructive) {
                    guard let server = nativeServerPendingRemoval else { return }
                    Task { await removeNativeServer(server) }
                }
                .settingsActionTint(theme)
                Button("Cancel", role: .cancel) { nativeServerPendingRemoval = nil }
                    .settingsActionTint(theme)
            } message: {
                Text(
                    "Codevisor edits only this entry in \(abbreviatePath(nativeServerPendingRemoval?.configPath ?? "")), backs the file up first, and keeps the entry so you can undo."
                )
            }
            .confirmationDialog(
                "Remove \(serverPendingRemoval?.name ?? "MCP server")?",
                isPresented: Binding(
                    get: { serverPendingRemoval != nil },
                    set: { if !$0 { serverPendingRemoval = nil } }
                ),
                titleVisibility: .visible
            ) {
                Button("Remove MCP Server", role: .destructive) {
                    guard let server = serverPendingRemoval else { return }
                    Task { await remove(server) }
                }
                .settingsActionTint(theme)
                Button("Cancel", role: .cancel) { serverPendingRemoval = nil }
                    .settingsActionTint(theme)
            } message: {
                Text("This removes its configuration and saved authorization from Codevisor.")
            }
    }

    /// Native servers discovered in harness configs, flattened per harness.
    private var nativeHarnessesWithServers: [ServerNativeMcpHarnessServers] {
        (nativeScan?.harnesses ?? []).filter { !$0.servers.isEmpty || $0.error != nil }
    }

    /// Candidates worth surfacing for import (not yet in the gateway).
    private var importCandidates: [ServerNativeMcpImportCandidate] {
        (nativeScan?.candidates ?? []).filter { !$0.alreadyManaged }
    }

    private var hasNativeContent: Bool {
        !nativeHarnessesWithServers.isEmpty
    }

    @ViewBuilder
    private var content: some View {
        if isLoading, servers.isEmpty {
            ProgressView()
                .controlSize(.regular)
                .tint(theme.isSystem ? nil : theme.accent)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .accessibilityLabel("Loading MCP servers")
        } else if errorMessage == nil, servers.isEmpty, !hasNativeContent {
            emptyState
        } else {
            serverList
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No MCP Servers", systemImage: "puzzlepiece.extension")
        } description: {
            Text("Add a server to make its tools available to every harness.")
        } actions: {
            Button {
                showingAdd = true
            } label: {
                Label("Add MCP Server…", systemImage: "plus")
            }
            .settingsActionTint(theme)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.horizontal, 40)
        .padding(.bottom, 24)
    }

    /// Codevisor's built-in tools (Browser Use, Computer Use) — machine
    /// capabilities, kept apart from user-added MCP servers.
    private var builtInServers: [ServerMcpServer] {
        servers.filter { $0.kind == "browserUse" || $0.kind == "computerUse" }
    }

    private var managedServers: [ServerMcpServer] {
        servers.filter { $0.kind != "browserUse" && $0.kind != "computerUse" }
    }

    private var serverList: some View {
        Form {
            if !builtInServers.isEmpty {
                Section {
                    ForEach(builtInServers) { server in
                        serverRow(server)
                    }
                } header: {
                    Text("Built-in Tools")
                }
            }

            Section {
                if let errorMessage, servers.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if managedServers.isEmpty {
                    Text("No MCP servers added yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(managedServers) { server in
                        serverRow(server)
                    }
                }
                Button {
                    showingAdd = true
                } label: {
                    Label("Add MCP Server…", systemImage: "plus")
                }
                .settingsActionTint(theme)
            } header: {
                Text("MCP Servers")
            }

            McpMachinesSection()

            if !importCandidates.isEmpty || importFeedback != nil {
                Section {
                    ForEach(importCandidates) { candidate in
                        importCandidateRow(candidate)
                    }
                    if importCandidates.count > 1 {
                        Button("Import All") {
                            Task { await importIdentities(importCandidates.map(\.identity)) }
                        }
                        .settingsActionTint(theme)
                        .disabled(!importingIdentities.isEmpty)
                    }
                } header: {
                    Text("Found in Your Harnesses")
                } footer: {
                    if let importFeedback {
                        Text(importFeedback)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            if hasNativeContent || lastNativeRemoval != nil {
                Section {
                    SettingsDisclosureRow(
                        "Installed in your harnesses (\(nativeServerCount))",
                        isExpanded: $showsNativeInstalled
                    ) {
                        ForEach(nativeHarnessesWithServers) { harness in
                            nativeHarnessGroup(harness)
                                .padding(.leading, 17)
                                .padding(.top, 6)
                        }
                    }
                } footer: {
                    if let error = nativeActionError {
                        Label(error, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else if let removal = lastNativeRemoval {
                        HStack(spacing: 8) {
                            Text(
                                "Removed \(removal.serverName) from \(harnessNames(for: [removal.harnessId])). The original file was backed up."
                            )
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            Button("Undo") {
                                Task { await undoNativeRemoval(removal) }
                            }
                            .buttonStyle(.borderless)
                            .settingsActionTint(theme)
                            .controlSize(.small)
                        }
                    }
                }
            }
        }
        .settingsPaneFormStyle(theme)
    }
}

// MARK: - Native discovery, import, and row actions
extension McpSettingsView {
    private var nativeServerCount: Int {
        nativeHarnessesWithServers.reduce(0) { $0 + $1.servers.count }
    }

    private func importCandidateRow(_ candidate: ServerNativeMcpImportCandidate) -> some View {
        McpImportCandidateRow(
            candidate: candidate,
            foundIn: harnessNames(for: candidate.foundIn),
            isImporting: importingIdentities.contains(candidate.identity),
            importDisabled: !importingIdentities.isEmpty,
            onImport: { Task { await importIdentities([candidate.identity]) } }
        )
    }

    private func removeNativeServer(_ server: ServerNativeMcpServer) async {
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

    private func undoNativeRemoval(_ removal: ServerNativeMcpRemoval) async {
        do {
            nativeScan = try await client.restoreNativeMcpRemoval(id: removal.id)
            lastNativeRemoval = nil
            nativeActionError = nil
        } catch {
            nativeActionError = ErrorReporter.userFacingMessage(for: error)
        }
    }

    private func setNativeEnabled(_ server: ServerNativeMcpServer, enabled: Bool) async {
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

    private func importIdentities(_ identities: [String]) async {
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
    private func feedback(for outcomes: [ServerNativeMcpImportOutcome]) -> String? {
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

    private func nativeHarnessGroup(_ harness: ServerNativeMcpHarnessServers) -> some View {
        SettingsDisclosureRow(isExpanded: nativeHarnessExpansion(harness.harnessId)) {
            // The bundled brand glyph, falling back to the catalog symbol.
            HarnessIcon(
                harnessId: harness.harnessId,
                fallbackSymbolName: harness.harnessSymbol ?? "cpu",
                size: 14
            )
            .frame(width: 16)
            Text("\(harness.harnessName) (\(harness.servers.count))")
                .foregroundStyle(theme.isSystem ? Color.primary : theme.textPrimary)
        } content: {
            if let error = harness.error {
                Label(
                    "Couldn't read \(abbreviatePath(harness.configPath)): \(error)",
                    systemImage: "exclamationmark.triangle"
                )
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(.leading, 23)
                .padding(.top, 6)
            }
            ForEach(harness.servers) { server in
                nativeServerRow(server)
                    .padding(.leading, 23)
                    .padding(.top, 6)
            }
        }
    }

    private func nativeHarnessExpansion(_ harnessId: String) -> Binding<Bool> {
        Binding(
            get: { expandedNativeHarnesses.contains(harnessId) },
            set: { expanded in
                if expanded {
                    expandedNativeHarnesses.insert(harnessId)
                } else {
                    expandedNativeHarnesses.remove(harnessId)
                }
            }
        )
    }

    private func nativeServerRow(_ server: ServerNativeMcpServer) -> some View {
        NativeMcpServerRow(
            server: server,
            setEnabled: { enabled in await setNativeEnabled(server, enabled: enabled) },
            showDetails: { selectedNativeServer = server },
            requestRemoval: { nativeServerPendingRemoval = server }
        )
    }

    private func harnessNames(for harnessIds: [String]) -> String {
        let names =
            nativeScan?.harnesses.reduce(into: [String: String]()) { partial, harness in
                partial[harness.harnessId] = harness.harnessName
            } ?? [:]
        return harnessIds.map { names[$0] ?? $0 }.joined(separator: ", ")
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func serverRow(_ server: ServerMcpServer) -> some View {
        McpManagedServerRow(
            server: server,
            browserConfiguration: browserConfiguration,
            computerPermissions: computerPermissions,
            setPreferredBrowser: { await setPreferredBrowser($0) },
            installBrowserExtension: { await installBrowserExtension() },
            beginOAuth: { try await beginOAuth(server) },
            setEnabled: { await setEnabled(server, enabled: $0) },
            showDetails: { selectedServer = server },
            edit: { editingServer = server },
            requestRemoval: { serverPendingRemoval = server }
        )
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            servers = try await client.listMcpServers()
            browserConfiguration = try? await client.browserUseConfiguration()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        // The inline setup visibility and the toggle's disabled state derive
        // from this model; make sure it is current whenever the pane loads.
        computerPermissions.refresh()
        // Native discovery is best-effort: older servers (404/501) or scan
        // failures simply hide the sections instead of surfacing an error.
        nativeScan = try? await client.listNativeMcps()
    }

    private func setPreferredBrowser(_ preference: String) async {
        do {
            browserConfiguration = try await client.setPreferredBrowser(preference)
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    private func installBrowserExtension() async {
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

    private func setEnabled(_ server: ServerMcpServer, enabled: Bool) async {
        if server.kind == "computerUse", enabled {
            computerPermissions.refresh()
            // The toggle is disabled while permissions are missing; this
            // guard just keeps a stale press from half-enabling.
            guard computerPermissions.allGranted else { return }
            environment.settings.setPermissionsSetupSkipped(false)
            environment.settings.setPermissionsReviewedVersion(AppUpdateModel.bundleVersion())
        }
        replace(server, with: serverWithEnabled(server, enabled))
        do {
            let updated = try await client.setMcpServerEnabled(id: server.id, enabled: enabled)
            replace(server, with: updated)
            if enabled, updated.connectionState == "needsSetup" {
                for _ in 0..<90 {
                    try? await Task.sleep(for: .seconds(2))
                    let refreshed = try await client.listMcpServers()
                    guard let current = refreshed.first(where: { $0.id == server.id }) else { break }
                    replace(updated, with: current)
                    if current.connectionState != "needsSetup" { break }
                }
            }
        } catch {
            replace(server, with: server)
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    private func remove(_ server: ServerMcpServer) async {
        do {
            try await client.removeMcpServer(id: server.id)
            servers.removeAll { $0.id == server.id }
            serverPendingRemoval = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    private func serverWithEnabled(_ server: ServerMcpServer, _ enabled: Bool) -> ServerMcpServer {
        var copy = server
        copy.enabled = enabled
        copy.connectionState = enabled ? "connecting" : "disconnected"
        return copy
    }

    private func replace(_ original: ServerMcpServer, with updated: ServerMcpServer) {
        guard let index = servers.firstIndex(where: { $0.id == original.id }) else { return }
        servers[index] = updated
    }

    private func beginOAuth(_ server: ServerMcpServer) async throws {
        let flow = try await client.startMcpOAuth(id: server.id)
        guard let url = URL(string: flow.authorizationUrl) else { return }
        NSWorkspace.shared.open(url)
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(2))
            await reload()
            if servers.first(where: { $0.id == server.id })?.connectionState == "connected" { break }
        }
    }
}

#Preview("MCP Settings") {
    McpSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 560, height: 460)
}
