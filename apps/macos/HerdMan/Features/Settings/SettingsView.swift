import SwiftUI
import HerdManCore
import ACPAgents

/// The app's Settings window (⌘, / HerdMan ▸ Settings…), with General and
/// Harnesses tabs in the standard macOS preferences style.
struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
            HarnessesSettingsView()
                .tabItem { Label("Harnesses", systemImage: "cpu") }
        }
        .frame(width: 520, height: 420)
    }
}

/// General settings — currently just "Delete all data".
struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @State private var showingConfirmation = false
    @State private var serverStatus: ServerStatusModel?

    var body: some View {
        Form {
            Section {
                serverStatusContent
            } header: {
                Text("Server")
            } footer: {
                Text("The local HerdMan server owns ACP sessions, storage, events, and terminal processes.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete all data")
                        .font(.headline)
                    Text("Removes all workspaces, sessions, cached settings, and onboarding state, then restarts setup. Your agents' own sessions are not affected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Delete All Data…", role: .destructive) {
                        showingConfirmation = true
                    }
                    .padding(.top, 4)
                }
                .padding(.vertical, 4)
            }
        }
        .formStyle(.grouped)
        .confirmationDialog(
            "Delete all HerdMan data?",
            isPresented: $showingConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Everything", role: .destructive) {
                environment.deleteAllData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. You'll be taken back through setup.")
        }
        .task { await refreshServerStatus() }
    }

    @ViewBuilder
    private var serverStatusContent: some View {
        if let serverStatus {
            if let errorMessage = serverStatus.errorMessage {
                Label(errorMessage, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
            }
            settingsRow("Name", value: serverStatus.info?.name ?? "Local HerdMan")
            settingsRow("Version", value: serverStatus.info?.version ?? serverStatus.health?.version ?? "Checking…")
            settingsRow("Database", value: serverStatus.health?.database.capitalized ?? "Checking…")
            if let info = serverStatus.info {
                settingsRow("Endpoint", value: "\(info.bindHost) (\(info.kind))")
            }
            updateRow(serverStatus.update)

            Button {
                Task { await refreshServerStatus() }
            } label: {
                if serverStatus.isRefreshing {
                    HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Refreshing…") }
                } else {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
            }
            .disabled(serverStatus.isRefreshing)
        } else if environment.serverClient == nil {
            Text("No server configured.")
                .foregroundStyle(.secondary)
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Checking server…")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func settingsRow(_ title: String, value: String) -> some View {
        HStack {
            Text(title)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func updateRow(_ update: ServerUpdateInfo?) -> some View {
        if let update {
            HStack {
                Label(
                    update.updateAvailable ? "Update available" : "Up to date",
                    systemImage: update.updateAvailable ? "arrow.down.circle" : "checkmark.circle"
                )
                Spacer()
                Text(update.updateAvailable
                     ? "\(update.currentVersion) → \(update.latestVersion)"
                     : update.currentVersion)
                    .foregroundStyle(.secondary)
            }
            if update.migrationState != "idle" {
                settingsRow("Migration", value: update.migrationState.capitalized)
            }
        } else {
            settingsRow("Update", value: "Checking…")
        }
    }

    private func refreshServerStatus() async {
        guard let serverClient = environment.serverClient else { return }
        if serverStatus == nil {
            serverStatus = ServerStatusModel(client: serverClient)
        }
        await serverStatus?.refresh()
    }
}

/// Harnesses settings — toggle the installed ACP harnesses you want to use,
/// rescan for newly installed ones, and see which known harnesses aren't
/// installed yet.
struct HarnessesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var all: [DiscoveredAgent] = []
    @State private var serverHarnesses: [ServerHarness]?
    @State private var isScanning = true
    @State private var isImporting = false
    @State private var showsNotInstalled = false

    private var installed: [DiscoveredAgent] { all.filter { $0.readiness.isReady } }
    private var notInstalled: [DiscoveredAgent] { all.filter { !$0.readiness.isReady } }
    private var serverInstalled: [ServerHarness] { (serverHarnesses ?? []).filter { $0.readiness.state == "ready" } }
    private var serverNotInstalled: [ServerHarness] { (serverHarnesses ?? []).filter { $0.readiness.state != "ready" } }

    var body: some View {
        Form {
            Section {
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning for harnesses…").foregroundStyle(.secondary)
                    }
                } else if serverHarnesses != nil {
                    if serverInstalled.isEmpty {
                        Text("No harnesses installed. Install Claude Code, Codex, or another ACP agent, then rescan.")
                            .foregroundStyle(.secondary)
                    } else {
                        ForEach(serverInstalled, id: \.id) { harness in
                            serverInstalledRow(harness)
                        }
                    }
                } else if installed.isEmpty {
                    Text("No harnesses installed. Install Claude Code, Codex, or another ACP agent, then rescan.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(installed) { harness in
                        installedRow(harness)
                    }
                }
            } header: {
                Text("Installed")
            } footer: {
                Text("Enabled harnesses appear in the chat composer's harness picker.")
            }

            if serverHarnesses != nil, !serverNotInstalled.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsNotInstalled) {
                        ForEach(serverNotInstalled, id: \.id) { harness in
                            serverNotInstalledRow(harness)
                        }
                    } label: {
                        Text("Not installed (\(serverNotInstalled.count))")
                            .foregroundStyle(.secondary)
                    }
                }
            } else if !notInstalled.isEmpty {
                Section {
                    DisclosureGroup(isExpanded: $showsNotInstalled) {
                        ForEach(notInstalled) { harness in
                            notInstalledRow(harness)
                        }
                    } label: {
                        Text("Not installed (\(notInstalled.count))")
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section {
                HStack {
                    Button {
                        Task { await scan() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isScanning)

                    Spacer()

                    Button {
                        isImporting = true
                        Task {
                            await environment.importSessions()
                            isImporting = false
                        }
                    } label: {
                        if isImporting {
                            HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Importing…") }
                        } else {
                            Label("Re-import sessions", systemImage: "square.and.arrow.down")
                        }
                    }
                    .disabled(isImporting || !environment.settings.importExternalSessions)
                    .help(environment.settings.importExternalSessions
                          ? "Refresh sessions from all installed harnesses"
                          : "Enable importing during setup to use this")
                }
            }
        }
        .formStyle(.grouped)
        .task { await scan() }
    }

    private func installedRow(_ harness: DiscoveredAgent) -> some View {
        Toggle(isOn: Binding(
            get: { environment.settings.isHarnessEnabled(harness.id) },
            set: { environment.settings.setHarness(harness.id, enabled: $0) }
        )) {
            HStack(spacing: 10) {
                Image(systemName: harness.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(harness.name)
            }
        }
        .toggleStyle(.switch)
    }

    private func serverInstalledRow(_ harness: ServerHarness) -> some View {
        Toggle(isOn: Binding(
            get: { harness.enabled },
            set: { enabled in
                Task { await setServerHarness(harness.id, enabled: enabled) }
            }
        )) {
            HStack(spacing: 10) {
                Image(systemName: harness.symbolName)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(harness.name)
            }
        }
        .toggleStyle(.switch)
    }

    private func notInstalledRow(_ harness: DiscoveredAgent) -> some View {
        HStack(spacing: 10) {
            Image(systemName: harness.symbolName)
                .foregroundStyle(.tertiary)
                .frame(width: 20)
            Text(harness.name)
                .foregroundStyle(.secondary)
            Spacer()
            Text(harness.readiness.detail ?? "Not installed")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private func serverNotInstalledRow(_ harness: ServerHarness) -> some View {
        HStack(spacing: 10) {
            Image(systemName: harness.symbolName)
                .foregroundStyle(.tertiary)
                .frame(width: 20)
            Text(harness.name)
                .foregroundStyle(.secondary)
            Spacer()
            Text(harness.readiness.detail ?? "Not installed")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
    }

    private func scan() async {
        isScanning = true
        if let serverClient = environment.serverClient,
           let harnesses = try? await serverClient.listHarnesses() {
            serverHarnesses = harnesses
            all = []
        } else {
            serverHarnesses = nil
            all = await environment.agentService.discoverAllHarnesses()
        }
        isScanning = false
    }

    private func setServerHarness(_ id: String, enabled: Bool) async {
        updateServerHarness(id, enabled: enabled)
        guard let serverClient = environment.serverClient else {
            environment.settings.setHarness(id, enabled: enabled)
            return
        }
        do {
            let updated = try await serverClient.setHarnessEnabled(id: id, enabled: enabled)
            replaceServerHarness(updated)
        } catch {
            updateServerHarness(id, enabled: !enabled)
        }
    }

    private func updateServerHarness(_ id: String, enabled: Bool) {
        guard var harnesses = serverHarnesses,
              let index = harnesses.firstIndex(where: { $0.id == id }) else { return }
        harnesses[index].enabled = enabled
        serverHarnesses = harnesses
    }

    private func replaceServerHarness(_ harness: ServerHarness) {
        guard var harnesses = serverHarnesses,
              let index = harnesses.firstIndex(where: { $0.id == harness.id }) else { return }
        harnesses[index] = harness
        serverHarnesses = harnesses
    }
}

#Preview("Settings") {
    SettingsView()
        .environment(AppEnvironment.preview())
}

#Preview("Harnesses") {
    HarnessesSettingsView()
        .environment(AppEnvironment.preview())
        .frame(width: 520, height: 420)
}
