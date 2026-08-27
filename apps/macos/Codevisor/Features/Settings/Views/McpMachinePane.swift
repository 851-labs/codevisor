import AppKit
import CodevisorCore
import CodevisorCoreMac
import CodevisorUI
import SwiftUI

/// One machine's MCP picture, rendered on its page: built-in
/// tools, the managed servers as they run THERE, import candidates, and
/// the native-config scan. Every control acts on that machine — the enable
/// toggle writes the per-machine overlay, which syncs to the fleet and is
/// enforced by that machine's server.
struct McpMachinePane: View {
    @Environment(AppEnvironment.self) var environment
    @Environment(\.theme) private var theme
    let machine: CodevisorMachine
    /// This Mac's TCC probes — consulted only when this pane IS the local
    /// machine; a remote machine's permissions are its own server's story.
    @State var permissions = ComputerUsePermissionsModel(
        probes: AppPreview.isRunning ? .granted : .live
    )

    @State var servers: [ServerMcpServer] = []
    @State var isLoading = true
    @State var errorMessage: String?
    @State private var selectedServer: ServerMcpServer?
    @State private var editingServer: ServerMcpServer?
    @State var serverPendingRemoval: ServerMcpServer?
    /// Native discovery is additive: nil (older server or scan failure)
    /// hides those rows entirely rather than blocking the managed list.
    @State var nativeScan: ServerNativeMcpScan?
    @State private var showsNativeInstalled = false
    @State private var selectedNativeServer: ServerNativeMcpServer?
    @State var importingIdentities: Set<String> = []
    @State var importFeedback: String?
    @State private var nativeServerPendingRemoval: ServerNativeMcpServer?
    @State var lastNativeRemoval: ServerNativeMcpRemoval?
    @State var nativeActionError: String?
    @State private var expandedNativeHarnesses: Set<String> = []
    @State var browserConfiguration: ServerBrowserUseConfiguration?

    var client: any CodevisorServerClienting {
        environment.machines.client(for: machine.id)
    }

    var body: some View {
        // Overlay flips re-derive every row's effective state immediately.
        let _ = environment.configSync.revisionsByNamespace["mcp-overlays"]
        Group {
            if isLoading, servers.isEmpty {
                Section {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text("Loading…").foregroundStyle(.secondary)
                    }
                }
            } else if let errorMessage, servers.isEmpty {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                }
            } else {
                paneContent
            }
        }
        .task(id: machine.id) { await reload() }
        .environment(\.settingsMachineId, machine.id)
        .sheet(item: $editingServer) { server in
            McpServerEditorSheet(initialServer: server) { values in
                let updated = try await client.updateMcpServer(id: server.id, request: values.updateBody)
                replace(server, with: updated)
                if updated.authType == "oauth" && updated.connectionState == "needsAuthorization" {
                    Task { try? await beginOAuth(updated) }
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
            Text("This removes its configuration and saved authorization from every machine.")
        }
    }

    @ViewBuilder
    private var paneContent: some View {
        let builtIn = servers.filter { $0.kind == "browserUse" || $0.kind == "computerUse" }
        let managed = servers.filter { $0.kind != "browserUse" && $0.kind != "computerUse" }
        if !builtIn.isEmpty {
            Section("Built-in Tools") {
                ForEach(builtIn) { server in
                    serverRow(server)
                }
            }
        }
        Section("MCP Servers") {
            if managed.isEmpty {
                Text("No MCP servers added yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(managed) { server in
                    serverRow(server)
                }
            }
            if let errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        importSection
        nativeSection
    }

    /// The row renders the machine-effective state: fleet-enabled AND not
    /// disabled here. A machine-disabled server shows as off regardless of
    /// what the fleet definition says.
    private func serverRow(_ server: ServerMcpServer) -> some View {
        McpManagedServerRow(
            server: displayServer(server),
            browserConfiguration: server.kind == "browserUse" ? browserConfiguration : nil,
            computerPermissions: machine.isLocal ? permissions : nil,
            setPreferredBrowser: { await setPreferredBrowser($0) },
            installBrowserExtension: { await installBrowserExtension() },
            beginOAuth: { try await beginOAuth(server) },
            setEnabled: { await setEnabled(server, enabled: $0) },
            showDetails: { selectedServer = server },
            edit: { editingServer = server },
            requestRemoval: { serverPendingRemoval = server }
        )
    }

    @ViewBuilder
    private var importSection: some View {
        let candidates = (nativeScan?.candidates ?? []).filter { !$0.alreadyManaged }
        if !candidates.isEmpty || importFeedback != nil {
            Section {
                ForEach(candidates) { candidate in
                    McpImportCandidateRow(
                        candidate: candidate,
                        foundIn: harnessNames(for: candidate.foundIn),
                        isImporting: importingIdentities.contains(candidate.identity),
                        importDisabled: !importingIdentities.isEmpty,
                        onImport: { Task { await importIdentities([candidate.identity]) } }
                    )
                }
                if candidates.count > 1 {
                    Button("Import All") {
                        Task { await importIdentities(candidates.map(\.identity)) }
                    }
                    .settingsActionTint(theme)
                    .disabled(!importingIdentities.isEmpty)
                }
                if let importFeedback {
                    Text(importFeedback)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text("Found in Your Harnesses")
            }
        }
    }

    @ViewBuilder
    private var nativeSection: some View {
        let harnesses = (nativeScan?.harnesses ?? []).filter { !$0.servers.isEmpty || $0.error != nil }
        if !harnesses.isEmpty || lastNativeRemoval != nil {
            let count = harnesses.reduce(0) { $0 + $1.servers.count }
            Section {
                SettingsDisclosureRow(
                    "Installed in your harnesses (\(count))",
                    isExpanded: $showsNativeInstalled
                ) {
                    ForEach(harnesses) { harness in
                        nativeHarnessGroup(harness)
                            .padding(.leading, 17)
                            .padding(.top, 6)
                    }
                }
            }
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

    private func nativeHarnessGroup(_ harness: ServerNativeMcpHarnessServers) -> some View {
        SettingsDisclosureRow(isExpanded: nativeHarnessExpansion(harness.harnessId)) {
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
                NativeMcpServerRow(
                    server: server,
                    setEnabled: { enabled in await setNativeEnabled(server, enabled: enabled) },
                    showDetails: { selectedNativeServer = server },
                    requestRemoval: { nativeServerPendingRemoval = server }
                )
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

    func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    func harnessNames(for harnessIds: [String]) -> String {
        let names =
            nativeScan?.harnesses.reduce(into: [String: String]()) { partial, harness in
                partial[harness.harnessId] = harness.harnessName
            } ?? [:]
        return harnessIds.map { names[$0] ?? $0 }.joined(separator: ", ")
    }

    func replace(_ original: ServerMcpServer, with updated: ServerMcpServer) {
        guard let index = servers.firstIndex(where: { $0.id == original.id }) else { return }
        servers[index] = updated
    }
}
