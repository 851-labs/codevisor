import CodevisorCore
import CodevisorTheming
import CodevisorUI
import SwiftUI
import UserNotifications

/// App settings, mirroring the macOS settings window's tabs as an iOS
/// navigation list: General, Appearance, Notifications, Machines, Harnesses,
/// MCPs, and Skills. Machine management (the old home-screen machine picker)
/// lives in Machines.
struct SettingsSheet: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            List {
                Section {
                    NavigationLink {
                        GeneralSettingsScreen()
                    } label: {
                        Label("General", systemImage: "gearshape")
                    }
                    NavigationLink {
                        AppearanceSettingsScreen()
                    } label: {
                        Label("Appearance", systemImage: "paintpalette")
                    }
                    NavigationLink {
                        NotificationsSettingsScreen()
                    } label: {
                        Label("Notifications", systemImage: "bell")
                    }
                }
                Section {
                    NavigationLink {
                        MachinesSettingsScreen()
                    } label: {
                        Label("Machines", systemImage: "desktopcomputer")
                    }
                } footer: {
                    Text("Harnesses, MCPs, and skills live on each machine — open a machine to manage them.")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDragIndicator(.visible)
    }
}

// MARK: - General

private struct GeneralSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isConfirmingDelete = false

    var body: some View {
        List {
            Section {
                Toggle(
                    "Share usage analytics",
                    isOn: Binding(
                        get: { environment.settings.shareAnalytics },
                        set: { environment.setShareAnalytics($0) }
                    )
                )
                Toggle(
                    "Send crash and error reports",
                    isOn: Binding(
                        get: { environment.settings.shareCrashReports },
                        set: { environment.setShareCrashReports($0) }
                    )
                )
            } header: {
                Text("Privacy")
            } footer: {
                Text("Helps improve Codevisor. Never includes your code or conversations.")
            }
            Section {
                Button("Delete All Data", role: .destructive) {
                    isConfirmingDelete = true
                }
            } footer: {
                Text("Removes this device's paired machines and local state. Nothing on your machines is changed.")
            }
        }
        .navigationTitle("General")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete all local data?",
            isPresented: $isConfirmingDelete,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) {
                environment.deleteAllData()
            }
        }
    }
}

// MARK: - Appearance

private struct AppearanceSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment

    var body: some View {
        List {
            Section("Mode") {
                Picker(
                    "Appearance",
                    selection: Binding(
                        get: { environment.settings.settings.themeMode },
                        set: { environment.settings.setThemeMode($0) }
                    )
                ) {
                    Text("Light").tag(ThemeMode.light)
                    Text("Dark").tag(ThemeMode.dark)
                    Text("System").tag(ThemeMode.system)
                }
                .pickerStyle(.segmented)
            }
        }
        .navigationTitle("Appearance")
        .navigationBarTitleDisplayMode(.inline)
    }
}

// MARK: - Notifications

private struct NotificationsSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var authorization: UNAuthorizationStatus = .notDetermined

    var body: some View {
        List {
            Section {
                Toggle(
                    "Chat notifications",
                    isOn: Binding(
                        get: { environment.settings.settings.notificationsEnabled },
                        set: { environment.settings.setNotificationsEnabled($0) }
                    )
                )
            } footer: {
                Text("Get notified when a chat finishes or needs your input.")
            }
            Section("Delivery") {
                Toggle(
                    "Show notifications when Codevisor isn't active",
                    isOn: Binding(
                        get: { environment.settings.settings.systemNotificationsEnabled },
                        set: { environment.settings.setSystemNotificationsEnabled($0) }
                    )
                )
                if authorization == .notDetermined {
                    Button("Allow System Notifications…") {
                        Task {
                            _ = try? await UNUserNotificationCenter.current()
                                .requestAuthorization(options: [.alert, .sound, .badge])
                            await refreshAuthorization()
                        }
                    }
                } else if authorization == .denied {
                    Button("Open Notification Settings…") {
                        if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                            UIApplication.shared.open(url)
                        }
                    }
                }
            }
            Section("Sounds") {
                Toggle(
                    "Play sounds",
                    isOn: Binding(
                        get: { environment.settings.settings.notificationSoundsEnabled },
                        set: { environment.settings.setNotificationSoundsEnabled($0) }
                    )
                )
            }
        }
        .navigationTitle("Notifications")
        .navigationBarTitleDisplayMode(.inline)
        .task { await refreshAuthorization() }
    }

    private func refreshAuthorization() async {
        authorization = await UNUserNotificationCenter.current()
            .notificationSettings().authorizationStatus
    }
}

// MARK: - Machines

/// Machine management: the paired remote machines (never the on-device
/// "local" pseudo-machine — this client has no local server). Each machine
/// nests its own scoped settings: status, harnesses, MCPs, skills.
struct MachinesSettingsScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var isAddingMachine = false

    private var machines: MachineController { environment.machines }

    private var remoteMachines: [CodevisorMachine] {
        machines.machines.filter { !$0.isLocal }
    }

    var body: some View {
        List {
            Section {
                ForEach(remoteMachines, id: \.id) { machine in
                    NavigationLink {
                        MachineDetailScreen(machineId: machine.id)
                    } label: {
                        HStack(spacing: 10) {
                            Image(systemName: machine.resolvedAppearance.symbolName)
                                .foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(machine.name)
                                Text(machines.statusByMachineId[machine.id]?.label ?? machine.baseURL.absoluteString)
                                    .font(.footnote)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            if machine.id == machines.selectedMachineId {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(.tint)
                            }
                        }
                    }
                }
            } footer: {
                Text("Run `codevisor setup` on a machine to print its address and token.")
            }
            Section {
                Button {
                    isAddingMachine = true
                } label: {
                    Label("Add Machine…", systemImage: "plus")
                }
            }
        }
        .navigationTitle("Machines")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $isAddingMachine) {
            AddMachineSheet()
        }
    }
}

/// One machine's page: connection info and the settings scoped to it —
/// harnesses, MCPs, and skills all live on the machine, so they're nested
/// here rather than floating at the top level.
private struct MachineDetailScreen: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss
    let machineId: String

    @State private var isRenaming = false
    @State private var renameText = ""

    private var machines: MachineController { environment.machines }
    private var machine: CodevisorMachine? { machines.machine(for: machineId) }

    var body: some View {
        List {
            if let machine {
                Section {
                    LabeledContent("Endpoint", value: machine.baseURL.absoluteString)
                    LabeledContent(
                        "Status",
                        value: machines.statusByMachineId[machine.id]?.label ?? "Connecting…"
                    )
                    if machine.id != machines.selectedMachineId {
                        Button("Use This Machine") {
                            machines.selectMachine(machine.id)
                            Task { await environment.prepareSelectedMachine() }
                        }
                    }
                }
                Section("On This Machine") {
                    NavigationLink {
                        HarnessesSettingsScreen(client: machines.client(for: machine.id))
                    } label: {
                        Label("Harnesses", systemImage: "cpu")
                    }
                    NavigationLink {
                        McpSettingsScreen(client: machines.client(for: machine.id))
                    } label: {
                        Label("MCPs", systemImage: "puzzlepiece.extension")
                    }
                    NavigationLink {
                        SkillsSettingsScreen(client: machines.client(for: machine.id))
                    } label: {
                        Label("Skills", systemImage: "book.closed")
                    }
                }
                Section {
                    Button("Rename…") {
                        renameText = machine.name
                        isRenaming = true
                    }
                    Button("Remove Machine…", role: .destructive) {
                        try? machines.removeMachine(machine.id)
                        dismiss()
                    }
                } footer: {
                    Text("Codevisor forgets this machine. Nothing on the machine itself is changed.")
                }
            }
        }
        .navigationTitle(machine?.name ?? "Machine")
        .navigationBarTitleDisplayMode(.inline)
        .alert("Rename Machine", isPresented: $isRenaming) {
            TextField("Name", text: $renameText)
            Button("Rename") {
                try? machines.renameMachine(machineId, to: renameText)
                isRenaming = false
            }
            Button("Cancel", role: .cancel) { isRenaming = false }
        }
    }
}

/// Manual pairing: address + token, validated against the server before the
/// machine is saved. The QR/deeplink flow covers the common path; this is the
/// fallback for typing coordinates from `codevisor setup`.
private struct AddMachineSheet: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.dismiss) private var dismiss

    @State private var host = ""
    @State private var name = ""
    @State private var token = ""
    @State private var isAdding = false
    @State private var errorMessage: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Address (host or host:port)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Name (optional)", text: $name)
                    SecureField("Connection token", text: $token)
                } footer: {
                    Text("Run `codevisor setup` on the machine to print its address and token.")
                }
                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("Add Machine")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") { add() }
                        .disabled(host.isEmpty || isAdding)
                }
            }
        }
    }

    private func add() {
        isAdding = true
        errorMessage = nil
        Task {
            do {
                let machine = try await environment.machines.addRemoteValidating(
                    host: host,
                    name: name.isEmpty ? nil : name,
                    token: token.isEmpty ? nil : token
                )
                environment.machines.selectMachine(machine.id)
                await environment.prepareSelectedMachine()
                dismiss()
            } catch {
                errorMessage = ErrorReporter.userFacingMessage(for: error)
                isAdding = false
            }
        }
    }
}

// MARK: - Harnesses

private struct HarnessesSettingsScreen: View {
    let client: any CodevisorServerClienting
    @State private var harnesses: [ServerHarness] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    private var installed: [ServerHarness] {
        harnesses.filter { $0.readiness.state != "notInstalled" }
    }

    private var notInstalled: [ServerHarness] {
        harnesses.filter { $0.readiness.state == "notInstalled" }
    }

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else {
                Section("Installed") {
                    ForEach(installed, id: \.id) { harness in
                        harnessRow(harness)
                    }
                }
                if !notInstalled.isEmpty {
                    Section("Not Installed") {
                        ForEach(notInstalled, id: \.id) { harness in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(harness.name)
                                if let hint = harness.installHint {
                                    Text(hint)
                                        .font(.footnote)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle("Harnesses")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    Task { await load() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel("Refresh harnesses")
            }
        }
        .task { await load() }
    }

    private func harnessRow(_ harness: ServerHarness) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(harness.name)
                if let auth = harness.auth, auth.state != "authenticated" {
                    Text("Sign in on your machine to use")
                        .font(.footnote)
                        .foregroundStyle(.orange)
                }
            }
            Spacer()
            Toggle(
                "Enable \(harness.name)",
                isOn: Binding(
                    get: { harness.enabled },
                    set: { enabled in
                        Task {
                            _ = try? await client.setHarnessEnabled(
                                id: harness.id, enabled: enabled
                            )
                            await load()
                        }
                    }
                )
            )
            .labelsHidden()
        }
    }

    private func load() async {
        do {
            harnesses = try await client.listHarnesses()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        isLoading = false
    }
}

// MARK: - MCPs

private struct McpSettingsScreen: View {
    let client: any CodevisorServerClienting
    @State private var servers: [ServerMcpServer] = []
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if servers.isEmpty {
                Text("No MCP servers managed by Codevisor yet.")
                    .foregroundStyle(.secondary)
            } else {
                Section("MCP Servers") {
                    ForEach(servers, id: \.id) { server in
                        serverRow(server)
                    }
                }
            }
        }
        .navigationTitle("MCPs")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
    }

    private func serverRow(_ server: ServerMcpServer) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(server.name)
                    if server.kind == "browserUse" || server.kind == "computerUse" {
                        Text("Built-in")
                            .font(.caption2)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(Color.secondary.opacity(0.15), in: Capsule())
                    }
                }
                Text(server.connectionState)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Toggle(
                "Enable \(server.name)",
                isOn: Binding(
                    get: { server.enabled },
                    set: { enabled in
                        Task {
                            _ = try? await client.setMcpServerEnabled(
                                id: server.id, enabled: enabled
                            )
                            await load()
                        }
                    }
                )
            )
            .labelsHidden()
        }
        .contextMenu {
            if server.canRemove != false {
                Button(role: .destructive) {
                    Task {
                        try? await client.removeMcpServer(id: server.id)
                        await load()
                    }
                } label: {
                    Label("Remove…", systemImage: "trash")
                }
            }
        }
    }

    private func load() async {
        do {
            servers = try await client.listMcpServers()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        isLoading = false
    }
}

// MARK: - Skills

private struct SkillsSettingsScreen: View {
    let client: any CodevisorServerClienting
    @State private var scan: ServerSkillsScan?
    @State private var isLoading = true
    @State private var errorMessage: String?

    var body: some View {
        List {
            if isLoading {
                HStack { Spacer(); ProgressView(); Spacer() }
            } else if let errorMessage {
                Text(errorMessage).foregroundStyle(.red)
            } else if let scan {
                if scan.global.isEmpty {
                    ContentUnavailableView {
                        Label("No Skills", systemImage: "book.closed")
                    } description: {
                        Text("Skills are reusable instruction sets shared with your coding agents.")
                    }
                } else {
                    Section("Global Skills") {
                        ForEach(scan.global, id: \.id) { skill in
                            skillRow(skill)
                        }
                    }
                }
            }
        }
        .navigationTitle("Skills")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("Sync") {
                    Task {
                        scan = try? await client.syncSkills(directoryNames: nil)
                    }
                }
            }
        }
        .task { await load() }
    }

    private func skillRow(_ skill: ServerGlobalSkill) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(skill.name)
            if let description = skill.description, !description.isEmpty {
                Text(description)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .contextMenu {
            Button(role: .destructive) {
                Task {
                    scan = try? await client.removeSkill(directoryName: skill.directoryName)
                }
            } label: {
                Label("Remove…", systemImage: "trash")
            }
        }
    }

    private func load() async {
        do {
            scan = try await client.listSkills()
            errorMessage = nil
        } catch {
            errorMessage = ErrorReporter.userFacingMessage(for: error)
        }
        isLoading = false
    }
}
