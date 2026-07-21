import AppKit
import CodevisorCore
import SwiftUI

struct McpSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
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

    var body: some View {
        content
            .background {
                if !theme.isSystem { theme.windowBackground }
            }
            .task { await reload() }
            .sheet(isPresented: $showingAdd) {
                McpServerEditorSheet(initialServer: nil) { values in
                    let created = try await environment.serverClient.createMcpServer(values.createBody)
                    servers.append(created)
                    servers.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
                    if created.authType == "oauth" {
                        Task {
                            do { try await beginOAuth(created) }
                            catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
                        }
                    }
                }
            }
            .sheet(item: $editingServer) { server in
                McpServerEditorSheet(initialServer: server) { values in
                    let updated = try await environment.serverClient.updateMcpServer(
                        id: server.id,
                        request: values.updateBody
                    )
                    replace(server, with: updated)
                    if updated.authType == "oauth" && updated.connectionState == "needsAuthorization" {
                        Task {
                            do { try await beginOAuth(updated) }
                            catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
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
                Text("Codevisor edits only this entry in \(abbreviatePath(nativeServerPendingRemoval?.configPath ?? "")), backs the file up first, and keeps the entry so you can undo.")
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

    private var serverList: some View {
        Form {
            Section {
                if let errorMessage, servers.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if servers.isEmpty {
                    Text("No MCP servers managed by Codevisor yet.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(servers) { server in
                        serverRow(server)
                    }
                }
            } header: {
                HStack {
                    Text("MCP Servers")
                    Spacer()
                    Button {
                        showingAdd = true
                    } label: {
                        Label("Add MCP Server", systemImage: "plus")
                    }
                    .labelStyle(.iconOnly)
                    .buttonStyle(.borderless)
                    .settingsActionTint(theme)
                    .help("Add MCP Server")
                }
            }
            .listRowBackground(theme.isSystem ? nil : theme.cardQuietBackground)

            if !importCandidates.isEmpty || importFeedback != nil {
                Section {
                    ForEach(importCandidates) { candidate in
                        importCandidateRow(candidate)
                    }
                } header: {
                    HStack {
                        Text("Found in Your Harnesses")
                        Spacer()
                        if importCandidates.count > 1 {
                            Button("Import All") {
                                Task { await importIdentities(importCandidates.map(\.identity)) }
                            }
                            .buttonStyle(.borderless)
                            .settingsActionTint(theme)
                            .disabled(!importingIdentities.isEmpty)
                        }
                    }
                } footer: {
                    if let importFeedback {
                        Text(importFeedback)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(theme.isSystem ? nil : theme.cardQuietBackground)
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
                            Text("Removed \(removal.serverName) from \(harnessNames(for: [removal.harnessId])). The original file was backed up.")
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
                .listRowBackground(theme.isSystem ? nil : theme.cardQuietBackground)
            }
        }
        .settingsPaneFormStyle(theme)
    }

    private var nativeServerCount: Int {
        nativeHarnessesWithServers.reduce(0) { $0 + $1.servers.count }
    }

    private func importCandidateRow(_ candidate: ServerNativeMcpImportCandidate) -> some View {
        HStack(spacing: 10) {
            Image(systemName: candidate.transport == "http" ? "globe" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(candidate.name).foregroundStyle(.primary)
                Text("Found in \(harnessNames(for: candidate.foundIn)) · \(candidate.identity)")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if importingIdentities.contains(candidate.identity) {
                ProgressView().controlSize(.small)
            } else {
                Button("Import") {
                    Task { await importIdentities([candidate.identity]) }
                }
                .settingsActionTint(theme)
                .controlSize(.small)
                .disabled(!importingIdentities.isEmpty)
                .help("Add to Codevisor's managed MCP servers")
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(candidate.name), found in \(harnessNames(for: candidate.foundIn))")
    }

    private func removeNativeServer(_ server: ServerNativeMcpServer) async {
        do {
            let result = try await environment.serverClient.removeNativeMcp(
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
            nativeScan = try await environment.serverClient.restoreNativeMcpRemoval(id: removal.id)
            lastNativeRemoval = nil
            nativeActionError = nil
        } catch {
            nativeActionError = ErrorReporter.userFacingMessage(for: error)
        }
    }

    private func setNativeEnabled(_ server: ServerNativeMcpServer, enabled: Bool) async {
        do {
            nativeScan = try await environment.serverClient.setNativeMcpEnabled(
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
            let result = try await environment.serverClient.importNativeMcps(identities: identities)
            nativeScan = result.scan
            importFeedback = feedback(for: result.outcomes)
            // The managed list changed too — refresh it (not the native scan,
            // which the result already replaced).
            servers = try await environment.serverClient.listMcpServers()
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
        HStack(spacing: 10) {
            Image(systemName: server.transport == "http" ? "globe" : "terminal")
                .foregroundStyle(.secondary)
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.serverName).foregroundStyle(.primary)
                    if server.scope == "project" {
                        nativeBadge("Project")
                    }
                    if server.enabled == false {
                        nativeBadge("Disabled")
                    }
                    if server.alreadyManaged {
                        nativeBadge("In Codevisor")
                    }
                }
                Text(server.identity)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if server.supportsDisable {
                Toggle(
                    "Enable \(server.serverName) in \(server.harnessName)",
                    isOn: Binding(
                        get: { server.enabled ?? true },
                        set: { enabled in Task { await setNativeEnabled(server, enabled: enabled) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            Menu {
                Button("Show Details…") { selectedNativeServer = server }
                if FileManager.default.fileExists(atPath: server.configPath) {
                    Button("Reveal Config in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: server.configPath)]
                        )
                    }
                }
                if server.supportsRemove {
                    Divider()
                    Button("Remove from \(server.harnessName)…", role: .destructive) {
                        nativeServerPendingRemoval = server
                    }
                }
            } label: {
                Label("More actions for \(server.serverName)", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .settingsActionTint(theme)
            .menuIndicator(.hidden)
            .help("More Actions")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(server.serverName), installed in \(server.harnessName)")
    }

    private func nativeBadge(_ text: String) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(
                RoundedRectangle(cornerRadius: 4)
                    .fill(theme.isSystem ? AnyShapeStyle(.quaternary) : AnyShapeStyle(theme.cardQuietBackground))
            )
            .foregroundStyle(.secondary)
    }

    private func harnessNames(for harnessIds: [String]) -> String {
        let names = nativeScan?.harnesses.reduce(into: [String: String]()) { partial, harness in
            partial[harness.harnessId] = harness.harnessName
        } ?? [:]
        return harnessIds.map { names[$0] ?? $0 }.joined(separator: ", ")
    }

    private func abbreviatePath(_ path: String) -> String {
        let home = NSHomeDirectory()
        return path.hasPrefix(home) ? "~" + path.dropFirst(home.count) : path
    }

    private func serverRow(_ server: ServerMcpServer) -> some View {
        HStack(spacing: 10) {
            Image(systemName: statusSymbol(server))
                .foregroundStyle(statusStyle(server))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).foregroundStyle(.primary)
                Text(statusText(server))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            let needsAuthorization = server.authType == "oauth" &&
                ["needsAuthorization", "expired", "error"].contains(server.connectionState)
            if needsAuthorization {
                Button("Connect…") {
                    Task { try? await beginOAuth(server) }
                }
                .settingsActionTint(theme)
                .controlSize(.small)
            } else {
                Toggle("Enable \(server.name)", isOn: Binding(
                    get: { server.enabled },
                    set: { enabled in Task { await setEnabled(server, enabled: enabled) } }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            Menu {
                Button("Show Details…") { selectedServer = server }
                Button("Edit…") { editingServer = server }
                Divider()
                Button("Remove…", role: .destructive) { serverPendingRemoval = server }
            } label: {
                Label("More actions for \(server.name)", systemImage: "ellipsis.circle")
            }
            .labelStyle(.iconOnly)
            .buttonStyle(.borderless)
            .settingsActionTint(theme)
            .menuIndicator(.hidden)
            .help("More Actions")
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(server.name), \(statusText(server)), \(server.enabled ? "enabled" : "disabled")")
    }

    private func statusText(_ server: ServerMcpServer) -> String {
        if server.authType == "oauth",
           ["needsAuthorization", "expired", "error"].contains(server.connectionState) {
            return "Not connected"
        }
        switch server.connectionState {
        case "connected": return "Connected · \(server.toolCount) tool\(server.toolCount == 1 ? "" : "s")"
        case "connecting": return "Connecting…"
        case "needsAuthorization": return "Authorization required"
        case "expired": return "Sign-in expired"
        case "error": return server.detail ?? "Connection failed"
        default: return server.enabled ? "Not connected" : "Disabled"
        }
    }

    private func statusSymbol(_ server: ServerMcpServer) -> String {
        if server.authType == "oauth",
           ["needsAuthorization", "expired", "error"].contains(server.connectionState) {
            return "circle"
        }
        switch server.connectionState {
        case "connected": return "checkmark.circle.fill"
        case "connecting": return "arrow.triangle.2.circlepath"
        case "needsAuthorization", "expired": return "person.crop.circle.badge.exclamationmark"
        case "error": return "exclamationmark.triangle.fill"
        default: return "circle"
        }
    }

    private func statusStyle(_ server: ServerMcpServer) -> AnyShapeStyle {
        if server.authType == "oauth",
           ["needsAuthorization", "expired", "error"].contains(server.connectionState) {
            return AnyShapeStyle(.secondary)
        }
        switch server.connectionState {
        case "connected": return AnyShapeStyle(theme.statusOK)
        case "needsAuthorization", "expired": return AnyShapeStyle(theme.statusWarn)
        case "error": return AnyShapeStyle(theme.statusError)
        default: return AnyShapeStyle(.secondary)
        }
    }

    private func reload() async {
        isLoading = true
        defer { isLoading = false }
        do {
            servers = try await environment.serverClient.listMcpServers()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        // Native discovery is best-effort: older servers (404/501) or scan
        // failures simply hide the sections instead of surfacing an error.
        nativeScan = try? await environment.serverClient.listNativeMcps()
    }

    private func setEnabled(_ server: ServerMcpServer, enabled: Bool) async {
        replace(server, with: serverWithEnabled(server, enabled))
        do {
            let updated = try await environment.serverClient.setMcpServerEnabled(id: server.id, enabled: enabled)
            replace(server, with: updated)
        } catch {
            replace(server, with: server)
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }

    private func remove(_ server: ServerMcpServer) async {
        do {
            try await environment.serverClient.removeMcpServer(id: server.id)
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
        let flow = try await environment.serverClient.startMcpOAuth(id: server.id)
        guard let url = URL(string: flow.authorizationUrl) else { return }
        NSWorkspace.shared.open(url)
        for _ in 0..<60 {
            try? await Task.sleep(for: .seconds(2))
            await reload()
            if servers.first(where: { $0.id == server.id })?.connectionState == "connected" { break }
        }
    }
}

private struct McpFormValues {
    var name: String
    var transport: String
    var location: String
    var arguments: [String]
    var authSelection: String
    var effectiveAuthType: String
    var bearerToken: String?
    var oauthScope: String?
    var oauthClientId: String?
    var oauthClientSecret: String?
    var headers: [String: String]
    var environment: [String: String]
    var removedHeaders: [String]
    var removedEnvironment: [String]

    var createBody: CreateMcpServerBody {
        CreateMcpServerBody(
            name: name,
            transport: transport,
            url: transport == "http" ? location : nil,
            command: transport == "stdio" ? location : nil,
            args: transport == "stdio" ? arguments : nil,
            env: transport == "stdio" && !environment.isEmpty ? environment : nil,
            headers: transport == "http" && !headers.isEmpty ? headers : nil,
            authType: transport == "http" ? (authSelection == "auto" ? nil : authSelection) : "none",
            bearerToken: transport == "http" ? bearerToken : nil,
            oauthScope: transport == "http" ? oauthScope : nil,
            oauthClientId: transport == "http" ? oauthClientId : nil,
            oauthClientSecret: transport == "http" ? oauthClientSecret : nil
        )
    }

    var updateBody: UpdateMcpServerBody {
        UpdateMcpServerBody(
            name: name,
            url: transport == "http" ? location : nil,
            command: transport == "stdio" ? location : nil,
            args: transport == "stdio" ? arguments : nil,
            env: transport == "stdio" && !environment.isEmpty ? environment : nil,
            headers: transport == "http" && !headers.isEmpty ? headers : nil,
            removeEnv: transport == "stdio" && !removedEnvironment.isEmpty ? removedEnvironment : nil,
            removeHeaders: transport == "http" && !removedHeaders.isEmpty ? removedHeaders : nil,
            authType: transport == "http" ? effectiveAuthType : "none",
            bearerToken: transport == "http" ? bearerToken : nil,
            oauthScope: transport == "http" ? oauthScope : nil,
            oauthClientId: transport == "http" ? oauthClientId : nil,
            oauthClientSecret: transport == "http" ? oauthClientSecret : nil
        )
    }
}

private struct McpSecretEntry: Identifiable {
    let id = UUID()
    var name: String
    var value: String
    let existing: Bool
}

private struct McpScrollingTextField: NSViewRepresentable {
    @Binding var text: String
    let placeholder: String
    let isEditable: Bool
    let isSelected: Bool
    let theme: Theme
    let onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let textField = NSTextField()
        textField.delegate = context.coordinator
        textField.isBordered = false
        textField.isBezeled = false
        textField.drawsBackground = false
        textField.focusRingType = .none
        textField.font = .systemFont(ofSize: 13)
        textField.usesSingleLineMode = true
        textField.maximumNumberOfLines = 1
        textField.cell?.isScrollable = true
        textField.cell?.wraps = false
        textField.cell?.lineBreakMode = .byClipping
        return textField
    }

    func updateNSView(_ textField: NSTextField, context: Context) {
        context.coordinator.parent = self
        textField.isEditable = isEditable
        textField.isSelectable = isEditable
        if theme.isSystem {
            textField.placeholderString = placeholder
            textField.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
        } else {
            textField.placeholderAttributedString = NSAttributedString(
                string: placeholder,
                attributes: [.foregroundColor: NSColor(theme.textTertiary)]
            )
            textField.textColor = NSColor(theme.textPrimary)
        }
        if textField.currentEditor() == nil, textField.stringValue != text {
            textField.stringValue = text
        }
    }

    final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: McpScrollingTextField

        init(_ parent: McpScrollingTextField) {
            self.parent = parent
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let textField = notification.object as? NSTextField else { return }
            parent.text = textField.stringValue
        }

        func controlTextDidBeginEditing(_ notification: Notification) {
            parent.onFocus()
        }
    }
}

/// A compact key/value editor using the shared container structure found in
/// System Settings: header, rows, and an integrated add/remove bar.
private struct McpKeyValueEditor: View {
    @Environment(\.theme) private var theme
    @Binding var entries: [McpSecretEntry]
    let nameHeading: String
    let namePrompt: String
    let valuePrompt: String
    let emptyLabel: String
    let addLabel: String
    @State private var selection: UUID?

    var body: some View {
        VStack(spacing: 0) {
            columns {
                Text(nameHeading)
                    .padding(.horizontal, 12)
            } trailing: {
                Text("Value")
                    .padding(.horizontal, 12)
            }
            .font(.body)
            .frame(height: 28)
            .background(containerBackground)

            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)

            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        if entries.isEmpty {
                            Text(emptyLabel)
                                .font(.system(size: 13))
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, minHeight: 24, maxHeight: 24)
                                .background(rowBackground(at: 0))
                        } else {
                            ForEach($entries) { $entry in
                                let entryID = entry.id
                                let index = entries.firstIndex(where: { $0.id == entryID }) ?? 0
                                let isSelected = selection == entryID

                                columns {
                                    McpScrollingTextField(
                                        text: $entry.name,
                                        placeholder: namePrompt,
                                        isEditable: !entry.existing,
                                        isSelected: isSelected,
                                        theme: theme,
                                        onFocus: { selection = entryID }
                                    )
                                    .padding(.horizontal, 12)
                                    .accessibilityLabel(nameHeading)
                                } trailing: {
                                    McpScrollingTextField(
                                        text: $entry.value,
                                        placeholder: entry.existing ? "Keep saved value" : valuePrompt,
                                        isEditable: true,
                                        isSelected: isSelected,
                                        theme: theme,
                                        onFocus: { selection = entryID }
                                    )
                                    .padding(.horizontal, 12)
                                    .accessibilityLabel(
                                        "Value for \(entry.name.isEmpty ? nameHeading : entry.name)"
                                    )
                                }
                                .frame(height: 24)
                                .background(
                                    isSelected
                                        ? selectedRowBackground
                                        : rowBackground(at: index)
                                )
                                .contentShape(Rectangle())
                                .onTapGesture { selection = entryID }
                                .id(entryID)
                            }
                        }
                    }
                }
                .scrollIndicators(entries.count > 4 ? .automatic : .hidden)
                .onChange(of: selection) { _, selectedID in
                    guard entries.count > 4, let selectedID else { return }
                    proxy.scrollTo(selectedID, anchor: .bottom)
                }
            }
            .frame(height: bodyHeight)

            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)

            HStack(spacing: 0) {
                Button {
                    let entry = McpSecretEntry(name: "", value: "", existing: false)
                    entries.append(entry)
                    selection = entry.id
                } label: {
                    Image(systemName: "plus")
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .settingsActionTint(theme)
                .accessibilityLabel(addLabel)
                .help(addLabel)

                Divider()
                    .overlay(theme.isSystem ? Color.clear : theme.separator)
                    .frame(height: 16)

                Button {
                    guard let selection else { return }
                    entries.removeAll { $0.id == selection }
                    self.selection = nil
                } label: {
                    Image(systemName: "minus")
                        .frame(width: 28, height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.borderless)
                .settingsActionTint(theme)
                .disabled(selection == nil)
                .accessibilityLabel("Remove selected \(nameHeading.lowercased())")
                .help("Remove Selected")

                Spacer()
            }
            .frame(height: 26)
            .background(containerBackground)
        }
        .background(rowBackground(at: 0))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            if !theme.isSystem {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            }
        }
        .onChange(of: entries.map(\.id)) { _, ids in
            if let selection, !ids.contains(selection) { self.selection = nil }
        }
        .accessibilityElement(children: .contain)
    }

    private var bodyHeight: CGFloat {
        let visibleRows = min(max(entries.count, 1), 4)
        return CGFloat(visibleRows * 24)
    }

    private var containerBackground: Color {
        if !theme.isSystem { return theme.cardQuietBackground }
        return Color(nsColor: NSColor.alternatingContentBackgroundColors[1])
    }

    private func rowBackground(at index: Int) -> Color {
        if !theme.isSystem {
            return index.isMultiple(of: 2) ? theme.composerBackground : theme.cardQuietBackground
        }
        let colors = NSColor.alternatingContentBackgroundColors
        return Color(nsColor: colors[index % colors.count])
    }

    private var selectedRowBackground: Color {
        theme.isSystem ? Color(nsColor: .selectedContentBackgroundColor) : theme.rowSelectedBackground
    }

    private func columns<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            leading()
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            trailing()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct McpServerEditorSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let initialServer: ServerMcpServer?
    let save: (McpFormValues) async throws -> Void
    @State private var name: String
    @State private var transport: String
    @State private var location: String
    @State private var authSelection: String
    @State private var detectedAuthType: String?
    @State private var isDetecting = false
    @State private var bearerToken: String
    @State private var oauthScope: String
    @State private var clientId = ""
    @State private var clientSecret = ""
    @State private var headerEntries: [McpSecretEntry]
    @State private var environmentEntries: [McpSecretEntry]
    @State private var isOAuthAdvancedExpanded = false
    @State private var isKeyValueEditorExpanded = false
    private let initialHeaderNames: Set<String>
    private let initialEnvironmentNames: Set<String>
    @State private var nameWasEdited: Bool
    @State private var isSaving = false
    @State private var errorMessage: String?

    init(
        initialServer: ServerMcpServer?,
        save: @escaping (McpFormValues) async throws -> Void
    ) {
        self.initialServer = initialServer
        self.save = save
        _name = State(initialValue: initialServer?.name ?? "")
        _transport = State(initialValue: initialServer?.transport ?? "http")
        _location = State(initialValue: initialServer?.url ?? CommandLineCodec.format(
            [initialServer?.command].compactMap { $0 } + (initialServer?.args ?? [])
        ))
        _authSelection = State(initialValue: initialServer?.authType ?? "auto")
        _detectedAuthType = State(initialValue: initialServer?.authType)
        _bearerToken = State(initialValue: "")
        _oauthScope = State(initialValue: initialServer?.oauthScope ?? "")
        _nameWasEdited = State(initialValue: initialServer != nil)
        let headerNames = Set(initialServer?.headerNames ?? [])
        let environmentNames = Set(initialServer?.environmentNames ?? [])
        initialHeaderNames = headerNames
        initialEnvironmentNames = environmentNames
        _headerEntries = State(initialValue: headerNames.sorted().map {
            McpSecretEntry(name: $0, value: "", existing: true)
        })
        _environmentEntries = State(initialValue: environmentNames.sorted().map {
            McpSecretEntry(name: $0, value: "", existing: true)
        })
    }

    var body: some View {
        VStack(spacing: 0) {
            Text(initialServer == nil ? "Add MCP Server" : "Edit MCP Server")
                .font(.headline)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 20)
                .padding(.top, 18)
            Form {
                Section("Connection") {
                    if initialServer == nil {
                        transportPicker
                            .onChange(of: transport) { _, value in
                                if value == "stdio" && authSelection == "oauth" {
                                    authSelection = "auto"
                                }
                            }
                    } else {
                        LabeledContent(
                            "Transport",
                            value: transport == "http" ? "HTTP" : "STDIO"
                        )
                    }
                    if transport == "http" {
                        TextField(
                            "Server URL",
                            text: $location,
                            prompt: Text(verbatim: "https://mcp.sentry.dev")
                        )
                        TextField("Name", text: Binding(
                            get: { name },
                            set: { name = $0; nameWasEdited = true }
                        ), prompt: Text("Sentry"))
                        authorizationPicker
                        if effectiveAuthType == "bearer" {
                            SecureField("Bearer Token", text: $bearerToken, prompt: Text("Paste token"))
                        }
                    } else {
                        TextField(
                            "Command",
                            text: $location,
                            prompt: Text("npx @playwright/mcp@latest")
                        )
                        TextField("Name", text: Binding(
                            get: { name },
                            set: { name = $0; nameWasEdited = true }
                        ), prompt: Text("Playwright"))
                    }
                }
                .listRowBackground(themedFormRowBackground)

                if effectiveAuthType == "oauth" {
                    Section {
                        McpDisclosureRow(
                            "Advanced OAuth",
                            isExpanded: $isOAuthAdvancedExpanded
                        ) {
                            VStack(spacing: 10) {
                                TextField("Scopes", text: $oauthScope, prompt: Text("org:read project:read"))
                                TextField("Client ID", text: $clientId, prompt: Text("Optional client ID"))
                                SecureField(
                                    "Client Secret",
                                    text: $clientSecret,
                                    prompt: Text("Optional client secret")
                                )
                            }
                        }
                    }
                    .listRowBackground(themedFormRowBackground)
                }

                Section {
                    McpDisclosureRow(
                        transport == "http" ? "HTTP Headers" : "Environment Variables",
                        isExpanded: $isKeyValueEditorExpanded
                    ) {
                        Group {
                            if transport == "http" {
                                McpKeyValueEditor(
                                    entries: $headerEntries,
                                    nameHeading: "Header",
                                    namePrompt: "Authorization",
                                    valuePrompt: "Bearer token",
                                    emptyLabel: "No custom headers",
                                    addLabel: "Add Header"
                                )
                            } else {
                                McpKeyValueEditor(
                                    entries: $environmentEntries,
                                    nameHeading: "Variable",
                                    namePrompt: "DEBUG",
                                    valuePrompt: "pw:mcp",
                                    emptyLabel: "No environment variables",
                                    addLabel: "Add Environment Variable"
                                )
                            }
                        }
                    }
                }
                .listRowBackground(themedFormRowBackground)

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(theme.statusError)
                            .font(.callout)
                    }
                    .listRowBackground(themedFormRowBackground)
                }
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                Spacer()
                cancelButton
                Button(initialServer == nil ? "Add" : "Save") { Task { await submit() } }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isSaving)
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 560, height: 570)
        .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
        .themedSurface(.sheet)
        .task(id: location) { await detectAuthorization() }
    }

    private var effectiveAuthType: String {
        guard transport == "http" else { return "none" }
        return authSelection == "auto" ? (detectedAuthType ?? "none") : authSelection
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
    }

    @ViewBuilder
    private var transportPicker: some View {
        if theme.isSystem {
            Picker("Transport", selection: $transport) {
                Text("HTTP").tag("http")
                Text("STDIO").tag("stdio")
            }
            .pickerStyle(.segmented)
        } else {
            LabeledContent("Transport") {
                McpThemedTransportPicker(selection: $transport, theme: theme)
                    .frame(width: 244)
            }
        }
    }

    @ViewBuilder
    private var authorizationPicker: some View {
        if theme.isSystem {
            Picker(selection: $authSelection) {
                Text(automaticAuthorizationLabel).tag("auto")
                Text("None").tag("none")
                Text("Bearer Token").tag("bearer")
                Text("OAuth").tag("oauth")
            } label: {
                authorizationLabel
            }
            .pickerStyle(.menu)
        } else {
            LabeledContent {
                McpThemedAuthorizationPicker(
                    selection: $authSelection,
                    automaticLabel: automaticAuthorizationLabel,
                    theme: theme
                )
                .frame(width: 244)
            } label: {
                authorizationLabel
            }
        }
    }

    private var authorizationLabel: some View {
        HStack(spacing: 6) {
            Text("Authorization")
            if isDetecting { ProgressView().controlSize(.small) }
        }
    }

    private var cancelButton: some View {
        Button("Cancel", role: .cancel) { dismiss() }
            .settingsActionTint(theme)
            .keyboardShortcut(.cancelAction)
    }

    private var automaticAuthorizationLabel: String {
        guard let detectedAuthType else { return "Automatic" }
        switch detectedAuthType {
        case "oauth": return "Automatic (OAuth)"
        case "bearer": return "Automatic (Bearer Token)"
        default: return "Automatic (None)"
        }
    }

    private var isValid: Bool {
        let hasValidLocation: Bool
        if transport == "stdio" {
            hasValidLocation = ((try? CommandLineCodec.parse(location))?.isEmpty == false)
        } else {
            hasValidLocation = !location.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
        return !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
            hasValidLocation &&
            validSecretEntries(headerEntries) && validSecretEntries(environmentEntries)
    }

    private func validSecretEntries(_ entries: [McpSecretEntry]) -> Bool {
        let names = entries.map { $0.name.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard names.allSatisfy({ !$0.isEmpty }), Set(names).count == names.count else { return false }
        return entries.allSatisfy { $0.existing || !$0.value.isEmpty }
    }

    private func changedValues(_ entries: [McpSecretEntry]) -> [String: String] {
        Dictionary(uniqueKeysWithValues: entries.compactMap { entry in
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            return name.isEmpty || entry.value.isEmpty ? nil : (name, entry.value)
        })
    }

    private func detectAuthorization() async {
        detectedAuthType = nil
        let scheme = URL(string: location)?.scheme?.lowercased()
        guard transport == "http", scheme == "http" || scheme == "https" else {
            return
        }
        do {
            try await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            isDetecting = true
            defer { isDetecting = false }
            let detection = try await environment.serverClient.detectMcpAuth(url: location)
            guard !Task.isCancelled else { return }
            detectedAuthType = detection.authType
            if !nameWasEdited, let suggestedName = detection.suggestedName {
                name = suggestedName
            }
        } catch is CancellationError {
            isDetecting = false
        } catch {
            isDetecting = false
        }
    }

    private func submit() async {
        isSaving = true
        defer { isSaving = false }
        do {
            let commandComponents = transport == "stdio" ? try CommandLineCodec.parse(location) : []
            try await save(McpFormValues(
                name: name,
                transport: transport,
                location: transport == "stdio" ? commandComponents[0] : location,
                arguments: transport == "stdio" ? Array(commandComponents.dropFirst()) : [],
                authSelection: authSelection,
                effectiveAuthType: effectiveAuthType,
                bearerToken: bearerToken.isEmpty ? nil : bearerToken,
                oauthScope: oauthScope.isEmpty ? nil : oauthScope,
                oauthClientId: clientId.isEmpty ? nil : clientId,
                oauthClientSecret: clientSecret.isEmpty ? nil : clientSecret,
                headers: changedValues(headerEntries),
                environment: changedValues(environmentEntries),
                removedHeaders: Array(initialHeaderNames.subtracting(headerEntries.map(\.name))),
                removedEnvironment: Array(initialEnvironmentNames.subtracting(environmentEntries.map(\.name)))
            ))
            dismiss()
        } catch let error as CommandLineCodec.ParseError {
            errorMessage = error.localizedDescription
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
    }
}

/// A macOS disclosure row whose full width is the trigger, preserving the
/// familiar disclosure triangle while providing a larger pointer target.
private struct McpDisclosureRow<Content: View>: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.theme) private var theme
    let title: String
    @Binding var isExpanded: Bool
    @ViewBuilder let content: () -> Content

    init(
        _ title: String,
        isExpanded: Binding<Bool>,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.title = title
        _isExpanded = isExpanded
        self.content = content
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Button {
                var transaction = Transaction()
                transaction.animation = reduceMotion ? nil : .easeInOut(duration: 0.15)
                withTransaction(transaction) {
                    isExpanded.toggle()
                }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(isExpanded ? 90 : 0))
                        .foregroundStyle(theme.isSystem ? Color.secondary : theme.textSecondary)
                        .accessibilityHidden(true)
                    Text(title)
                        .foregroundStyle(theme.isSystem ? Color.primary : theme.textPrimary)
                    Spacer(minLength: 0)
                }
                .frame(maxWidth: .infinity, minHeight: 20, alignment: .leading)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel(title)
            .accessibilityValue(isExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(isExpanded ? "Collapses this section" : "Expands this section")

            if isExpanded {
                content()
                    .padding(.top, 8)
            }
        }
    }
}

/// The native AppKit segmented bezel doesn't consume SwiftUI theme tokens.
/// This two-choice equivalent preserves the segmented interaction model while
/// using the active palette for its surface, selection, border, and labels.
private struct McpThemedTransportPicker: View {
    private struct Option: Identifiable {
        let id: String
        let label: String
    }

    @Binding var selection: String
    let theme: Theme
    @FocusState private var focusedOption: String?

    private let options = [
        Option(id: "http", label: "HTTP"),
        Option(id: "stdio", label: "STDIO"),
    ]

    var body: some View {
        HStack(spacing: 2) {
            ForEach(options) { option in
                let isSelected = selection == option.id
                Button {
                    selection = option.id
                } label: {
                    Text(option.label)
                        .foregroundStyle(isSelected ? theme.textPrimary : theme.textSecondary)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .focused($focusedOption, equals: option.id)
                .background {
                    RoundedRectangle(cornerRadius: 5, style: .continuous)
                        .fill(isSelected ? theme.rowSelectedBackground : Color.clear)
                }
                .overlay {
                    if isSelected {
                        RoundedRectangle(cornerRadius: 5, style: .continuous)
                            .strokeBorder(theme.border, lineWidth: 1)
                    }
                }
                .accessibilityLabel(option.label)
                .accessibilityValue(isSelected ? "Selected" : "Not selected")
                .accessibilityAddTraits(isSelected ? .isSelected : [])
            }
        }
        .padding(2)
        .background {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(theme.composerBackground)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(theme.border, lineWidth: 1)
        }
        .onMoveCommand { direction in
            guard let currentIndex = options.firstIndex(where: { $0.id == selection }) else { return }
            let nextIndex: Int
            switch direction {
            case .left: nextIndex = max(options.startIndex, currentIndex - 1)
            case .right: nextIndex = min(options.index(before: options.endIndex), currentIndex + 1)
            default: return
            }
            selection = options[nextIndex].id
            focusedOption = selection
        }
    }
}

/// A theme-token-backed macOS pop-up button for the short authorization list.
/// Menu items retain the familiar checkmark selection while the collapsed
/// control uses the same surface and border language as the themed form.
private struct McpThemedAuthorizationPicker: View {
    private struct Option: Identifiable {
        let id: String
        let label: String
    }

    @Binding var selection: String
    let automaticLabel: String
    let theme: Theme

    private var options: [Option] {
        [
            Option(id: "auto", label: automaticLabel),
            Option(id: "none", label: "None"),
            Option(id: "bearer", label: "Bearer Token"),
            Option(id: "oauth", label: "OAuth"),
        ]
    }

    private var selectedLabel: String {
        options.first { $0.id == selection }?.label ?? automaticLabel
    }

    var body: some View {
        Menu {
            ForEach(options) { option in
                Button {
                    selection = option.id
                } label: {
                    if selection == option.id {
                        Label(option.label, systemImage: "checkmark")
                    } else {
                        Text(option.label)
                    }
                }
            }
        } label: {
            HStack(spacing: 8) {
                Text(selectedLabel)
                    .foregroundStyle(theme.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 8)
                Image(systemName: "chevron.up.chevron.down")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(theme.textSecondary)
                    .accessibilityHidden(true)
            }
            .padding(.horizontal, 9)
            .frame(maxWidth: .infinity)
            .frame(height: 28)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(theme.composerBackground)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(theme.border, lineWidth: 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .accessibilityLabel("Authorization")
        .accessibilityValue(selectedLabel)
    }
}

private struct McpServerDetailSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let server: ServerMcpServer
    let didChange: () async -> Void
    @State private var tools: [ServerMcpTool] = []
    @State private var isLoadingTools = false
    @State private var errorMessage: String?
    @State private var confirmingRemoval = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: server.connectionState == "connected" ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(
                        server.connectionState == "connected"
                            ? AnyShapeStyle(theme.statusOK)
                            : AnyShapeStyle(.secondary)
                    )
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.headline)
                    Text(connectionStateLabel)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            Form {
                Section("Connection") {
                    LabeledContent("Transport", value: server.transport == "http" ? "HTTP" : "Local command")
                    if let url = server.url {
                        LabeledContent("Server URL") {
                            Text(url).textSelection(.enabled)
                        }
                    }
                    if let command = server.command {
                        LabeledContent("Command") {
                            Text(([command] + server.args).joined(separator: " "))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if server.transport == "http" {
                        LabeledContent("Authorization", value: authorizationLabel)
                    }
                    if server.transport == "http", let count = server.headerNames?.count, count > 0 {
                        LabeledContent("HTTP Headers", value: "\(count) configured")
                    }
                    if server.transport == "stdio", let count = server.environmentNames?.count, count > 0 {
                        LabeledContent(
                            "Environment Variables",
                            value: "\(count) variable\(count == 1 ? "" : "s")"
                        )
                    }
                    if server.transport == "http", server.authType == "oauth" {
                        Text("Authorization renews automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .listRowBackground(themedFormRowBackground)
                Section("Tools") {
                    if isLoadingTools {
                        ProgressView().controlSize(.small)
                    } else if tools.isEmpty {
                        Text("No tools available").foregroundStyle(.secondary)
                    } else {
                        ForEach(tools) { tool in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(tool.title ?? tool.name)
                                if let description = tool.description {
                                    Text(description).font(.caption).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
                .listRowBackground(themedFormRowBackground)
                if let errorMessage { Text(errorMessage).foregroundStyle(theme.statusError) }
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                Button("Remove…", role: .destructive) { confirmingRemoval = true }
                    .settingsActionTint(theme)
                if server.authType == "oauth" && server.connectionState == "connected" {
                    Button("Sign Out") { Task { await disconnect() } }
                        .settingsActionTint(theme)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 540, height: 470)
        .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
        .themedSurface(.sheet)
        .task { await loadTools() }
        .confirmationDialog(
            "Remove \(server.name)?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove MCP Server", role: .destructive) { Task { await remove() } }
                .settingsActionTint(theme)
            Button("Cancel", role: .cancel) {}
                .settingsActionTint(theme)
        } message: {
            Text("This removes its configuration and saved authorization from Codevisor.")
        }
    }

    private var connectionStateLabel: String {
        switch server.connectionState {
        case "connected": return "Connected · \(server.toolCount) tool\(server.toolCount == 1 ? "" : "s")"
        case "connecting": return "Connecting…"
        case "needsAuthorization": return "Authorization required"
        case "expired": return "Sign-in expired"
        case "error": return server.detail ?? "Connection failed"
        default: return server.enabled ? "Not connected" : "Disabled"
        }
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
    }

    private var authorizationLabel: String {
        switch server.authType {
        case "oauth": return "OAuth"
        case "bearer": return "Bearer token"
        default: return "None"
        }
    }

    private func loadTools() async {
        isLoadingTools = true
        defer { isLoadingTools = false }
        do { tools = try await environment.serverClient.listMcpTools(id: server.id) }
        catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
    }

    private func remove() async {
        do {
            try await environment.serverClient.removeMcpServer(id: server.id)
            await didChange()
            dismiss()
        } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
    }

    private func disconnect() async {
        do {
            _ = try await environment.serverClient.disconnectMcpOAuth(id: server.id)
            await didChange()
            dismiss()
        } catch { errorMessage = ErrorReporter.userFacingMessage(for: error) }
    }
}

#Preview("MCP Settings") {
    McpSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 560, height: 460)
}

/// Read-only detail for an MCP server that lives in a harness's own config
/// file. Secret values never reach the client, so env vars and headers render
/// as names only.
private struct NativeMcpDetailSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.theme) private var theme
    let server: ServerNativeMcpServer

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: server.transport == "http" ? "globe" : "terminal")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.serverName).font(.headline)
                    Text("Installed in \(server.harnessName)\(server.scope == "project" ? " · Project" : "")")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(.horizontal, 20)
            .padding(.top, 18)
            Form {
                Section("Connection") {
                    LabeledContent("Transport", value: server.transport == "http" ? "HTTP" : "Local command")
                    if let url = server.url {
                        LabeledContent("Server URL") {
                            Text(url).textSelection(.enabled)
                        }
                    }
                    if let command = server.command {
                        LabeledContent("Command") {
                            Text(([command] + server.args).joined(separator: " "))
                                .font(.body.monospaced())
                                .textSelection(.enabled)
                        }
                    }
                    if let enabled = server.enabled {
                        LabeledContent("Enabled in \(server.harnessName)", value: enabled ? "Yes" : "No")
                    }
                }
                .listRowBackground(themedFormRowBackground)
                if !server.headerNames.isEmpty || !server.envNames.isEmpty {
                    Section("Secrets") {
                        if !server.headerNames.isEmpty {
                            LabeledContent("HTTP Headers", value: server.headerNames.joined(separator: ", "))
                        }
                        if !server.envNames.isEmpty {
                            LabeledContent("Environment Variables", value: server.envNames.joined(separator: ", "))
                        }
                        Text("Values stay in the harness's config file and are never read into Codevisor.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                    .listRowBackground(themedFormRowBackground)
                }
                Section("Source") {
                    LabeledContent("Config File") {
                        Text(server.configPath)
                            .font(.body.monospaced())
                            .textSelection(.enabled)
                            .lineLimit(2)
                            .truncationMode(.middle)
                    }
                }
                .listRowBackground(themedFormRowBackground)
            }
            .formStyle(.grouped)
            .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
            Divider()
                .overlay(theme.isSystem ? Color.clear : theme.separator)
            HStack {
                if FileManager.default.fileExists(atPath: server.configPath) {
                    Button("Reveal Config in Finder") {
                        NSWorkspace.shared.activateFileViewerSelecting(
                            [URL(fileURLWithPath: server.configPath)]
                        )
                    }
                    .settingsActionTint(theme)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .settingsActionTint(theme)
                    .keyboardShortcut(.defaultAction)
            }
            .padding()
            .themedSurface(.sheet)
        }
        .frame(width: 540, height: 420)
        .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
        .themedSurface(.sheet)
    }

    private var themedFormRowBackground: Color? {
        theme.isSystem ? nil : theme.cardQuietBackground
    }
}
