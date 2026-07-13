import AppKit
import HerdManCore
import SwiftUI

struct McpSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var servers: [ServerMcpServer] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var showingAdd = false
    @State private var selectedServer: ServerMcpServer?
    @State private var editingServer: ServerMcpServer?
    @State private var serverPendingRemoval: ServerMcpServer?

    var body: some View {
        Form {
            Section {
                if isLoading && servers.isEmpty {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Loading MCP servers…").foregroundStyle(.secondary)
                    }
                } else if let errorMessage, servers.isEmpty {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.secondary)
                } else if servers.isEmpty {
                    ContentUnavailableView(
                        "No MCP Servers",
                        systemImage: "puzzlepiece.extension",
                        description: Text("Add a server to make its tools available to every harness.")
                    )
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
                    .help("Add MCP Server")
                }
            }
        }
        .formStyle(.grouped)
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
            Button("Cancel", role: .cancel) { serverPendingRemoval = nil }
        } message: {
            Text("This removes its configuration and saved authorization from HerdMan.")
        }
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
            .menuIndicator(.hidden)
            .help("More Actions")
        }
        .padding(.vertical, 2)
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
        case "connected": return AnyShapeStyle(.green)
        case "needsAuthorization", "expired": return AnyShapeStyle(.orange)
        case "error": return AnyShapeStyle(.red)
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
        textField.placeholderString = placeholder
        textField.isEditable = isEditable
        textField.isSelectable = isEditable
        textField.textColor = isSelected ? .alternateSelectedControlTextColor : .labelColor
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
                                        ? Color(nsColor: .selectedContentBackgroundColor)
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
                .accessibilityLabel(addLabel)
                .help(addLabel)

                Divider().frame(height: 16)

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
        Color(nsColor: NSColor.alternatingContentBackgroundColors[1])
    }

    private func rowBackground(at index: Int) -> Color {
        let colors = NSColor.alternatingContentBackgroundColors
        return Color(nsColor: colors[index % colors.count])
    }

    private func columns<Leading: View, Trailing: View>(
        @ViewBuilder leading: () -> Leading,
        @ViewBuilder trailing: () -> Trailing
    ) -> some View {
        HStack(spacing: 0) {
            leading()
                .frame(maxWidth: .infinity, alignment: .leading)
            Divider()
            trailing()
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

private struct McpServerEditorSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
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
            ScrollView {
                VStack(spacing: 0) {
                    Form {
                        Section("Connection") {
                            if initialServer == nil {
                                Picker("Transport", selection: $transport) {
                                    Text("HTTP").tag("http")
                                    Text("Local Command").tag("stdio")
                                }
                                .pickerStyle(.segmented)
                                .onChange(of: transport) { _, value in
                                    if value == "stdio" && authSelection == "oauth" {
                                        authSelection = "auto"
                                    }
                                }
                            } else {
                                LabeledContent(
                                    "Transport",
                                    value: transport == "http" ? "HTTP" : "Local Command"
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
                            } else {
                                TextField("Name", text: Binding(
                                    get: { name },
                                    set: { name = $0; nameWasEdited = true }
                                ), prompt: Text("Playwright"))
                                TextField(
                                    "Command",
                                    text: $location,
                                    prompt: Text("npx @playwright/mcp@latest")
                                )
                            }
                        }
                        if transport == "http" {
                            Section("Authentication") {
                                Picker(selection: $authSelection) {
                                    Text(automaticAuthorizationLabel).tag("auto")
                                    Text("None").tag("none")
                                    Text("Bearer Token").tag("bearer")
                                    Text("OAuth").tag("oauth")
                                } label: {
                                    HStack(spacing: 6) {
                                        Text("Authorization")
                                        if isDetecting { ProgressView().controlSize(.small) }
                                    }
                                }
                                if effectiveAuthType == "bearer" {
                                    SecureField("Bearer Token", text: $bearerToken, prompt: Text("Paste token"))
                                }
                            }
                        }
                    }
                    .formStyle(.grouped)
                    .scrollDisabled(true)
                    .frame(height: primaryFormHeight)

                    VStack(alignment: .leading, spacing: 8) {
                        Text(transport == "http" ? "HTTP Headers" : "Environment")
                            .font(.headline)

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
                    .padding(.horizontal, 20)
                    .padding(.bottom, 12)

                    if effectiveAuthType == "oauth" {
                        Form {
                            Section("OAuth Advanced") {
                                TextField("Scopes", text: $oauthScope, prompt: Text("org:read project:read"))
                                TextField("Client ID", text: $clientId, prompt: Text("Optional client ID"))
                                SecureField("Client Secret", text: $clientSecret, prompt: Text("Optional client secret"))
                            }
                        }
                        .formStyle(.grouped)
                        .scrollDisabled(true)
                        .frame(height: 190)
                    }

                    if let errorMessage {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 20)
                    }
                }
            }
            Divider()
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(initialServer == nil ? "Add" : "Save") { Task { await submit() } }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!isValid || isSaving)
            }
            .padding()
        }
        .frame(width: 560, height: 570)
        .task(id: location) { await detectAuthorization() }
    }

    private var effectiveAuthType: String {
        guard transport == "http" else { return "none" }
        return authSelection == "auto" ? (detectedAuthType ?? "none") : authSelection
    }

    private var primaryFormHeight: CGFloat {
        if transport == "stdio" { return 190 }
        return effectiveAuthType == "bearer" ? 305 : 270
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

private struct McpServerDetailSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
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
                    .foregroundStyle(server.connectionState == "connected" ? AnyShapeStyle(.green) : AnyShapeStyle(.secondary))
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
                        LabeledContent("Environment", value: "\(count) variable\(count == 1 ? "" : "s")")
                    }
                    if server.transport == "http", server.authType == "oauth" {
                        Text("Authorization renews automatically.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
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
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            Divider()
            HStack {
                Button("Remove…", role: .destructive) { confirmingRemoval = true }
                if server.authType == "oauth" && server.connectionState == "connected" {
                    Button("Sign Out") { Task { await disconnect() } }
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 540, height: 470)
        .task { await loadTools() }
        .confirmationDialog(
            "Remove \(server.name)?",
            isPresented: $confirmingRemoval,
            titleVisibility: .visible
        ) {
            Button("Remove MCP Server", role: .destructive) { Task { await remove() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This removes its configuration and saved authorization from HerdMan.")
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
