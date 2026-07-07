import SwiftUI
import AppKit
import HerdManCore

enum SettingsTab: String {
    case general
    case appearance
    case machines
    case harnesses
}

/// Routes programmatic Settings navigation (e.g. the sidebar's
/// "Manage machines…" opens Settings on the Machines tab).
@MainActor
@Observable
final class SettingsRouter {
    static let shared = SettingsRouter()
    var selectedTab: SettingsTab = .general
}

/// The app's Settings window (⌘, / HerdMan ▸ Settings…), with General,
/// Appearance, Machines, and Harnesses tabs in the standard macOS
/// preferences style.
struct SettingsView: View {
    @Bindable private var router = SettingsRouter.shared
    @Environment(\.theme) private var theme

    var body: some View {
        TabView(selection: $router.selectedTab) {
            GeneralSettingsView()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(SettingsTab.general)
            AppearanceSettingsView()
                .tabItem { Label("Appearance", systemImage: "paintpalette") }
                .tag(SettingsTab.appearance)
            MachinesSettingsView()
                .tabItem { Label("Machines", systemImage: "desktopcomputer") }
                .tag(SettingsTab.machines)
            HarnessesSettingsView()
                .tabItem { Label("Harnesses", systemImage: "cpu") }
                .tag(SettingsTab.harnesses)
        }
        .frame(width: 520, height: 420)
        // When themed, drop the grouped forms' own backdrop so the theme
        // surface (painted by ThemedRoot) shows through, and paint the tab
        // strip opaquely on-theme; system themes keep the native look.
        .scrollContentBackground(theme.isSystem ? .automatic : .hidden)
        .themedToolbarBackground(theme, surface: theme.windowBackground)
    }
}

/// General settings — currently just "Delete all data".
struct GeneralSettingsView: View {
    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    @State private var showingConfirmation = false
    @State private var serverStatus: ServerStatusModel?
    @State private var tokenCopied = false
    @State private var tokenError: String?

    var body: some View {
        Form {
            Section {
                serverStatusContent
            } header: {
                Text("Server")
            }

            Section {
                HStack(alignment: .center) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Connection token")
                        Text(tokenError ?? "Lets another device running HerdMan connect to this Mac.")
                            .font(.callout)
                            .foregroundStyle(tokenError == nil ? AnyShapeStyle(.secondary) : AnyShapeStyle(theme.statusWarn))
                    }
                    Spacer()
                    Button {
                        copyConnectionToken()
                    } label: {
                        if tokenCopied {
                            Label("Copied", systemImage: "checkmark")
                        } else {
                            Label("Copy", systemImage: "doc.on.doc")
                        }
                    }
                }
            } header: {
                Text("Remote Access")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete all data")
                        .font(.headline)
                    Text("Removes all projects, sessions, cached settings, and onboarding state, then restarts setup. Your agents' own sessions are not affected.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Delete all data…", role: .destructive) {
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
            Button("Delete everything", role: .destructive) {
                environment.deleteAllData()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This can't be undone. You'll be taken back through setup.")
        }
        .task(id: environment.machines.selectedMachineId) {
            serverStatus = ServerStatusModel(client: environment.serverClient)
            await refreshServerStatus()
        }
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
        if serverStatus == nil {
            serverStatus = ServerStatusModel(client: environment.serverClient)
        }
        await serverStatus?.refresh()
    }

    /// Issues a fresh token from this Mac's server and puts it on the
    /// clipboard, for pasting into another device's Add Remote Machine form.
    private func copyConnectionToken() {
        Task {
            do {
                let token = try await environment.machines.issueLocalConnectionToken()
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(token, forType: .string)
                tokenError = nil
                tokenCopied = true
                try? await Task.sleep(for: .seconds(2))
                tokenCopied = false
            } catch {
                tokenError = "Couldn't issue a token: this Mac's server isn't running."
            }
        }
    }
}

/// Harnesses settings — toggle the installed ACP harnesses you want to use,
/// rescan for newly installed ones, and see which known harnesses aren't
/// installed yet.
struct HarnessesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var serverHarnesses: [ServerHarness] = []
    @State private var isScanning = true
    @State private var scanError: String?
    @State private var showsNotInstalled = false

    private var serverInstalled: [ServerHarness] { serverHarnesses.filter(\.isReady) }
    private var serverNotInstalled: [ServerHarness] { serverHarnesses.filter { !$0.isReady } }

    var body: some View {
        Form {
            Section {
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning for harnesses…").foregroundStyle(.secondary)
                    }
                } else if scanError != nil {
                    // Unreachable is not "nothing installed" — say so.
                    Text("Couldn't reach this machine's server. Check Settings → General, then refresh.")
                        .foregroundStyle(.secondary)
                } else if serverInstalled.isEmpty {
                    Text("No harnesses installed. Install Claude Code, Codex, or another ACP agent, then rescan.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(serverInstalled, id: \.id) { harness in
                        serverInstalledRow(harness)
                    }
                }
            } header: {
                Text("Installed")
            } footer: {
                Text("Enabled harnesses appear in the chat composer's harness picker.")
            }

            if !serverNotInstalled.isEmpty {
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
            }

            Section {
                HStack {
                    Button {
                        Task { await scan() }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(isScanning)
                }
            }
        }
        .formStyle(.grouped)
        .task { await scan() }
    }

    private func serverInstalledRow(_ harness: ServerHarness) -> some View {
        Toggle(isOn: Binding(
            get: { harness.enabled },
            set: { enabled in
                Task { await setServerHarness(harness.id, enabled: enabled) }
            }
        )) {
            HStack(spacing: 10) {
                HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 15)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                Text(harness.name)
            }
        }
        .toggleStyle(.switch)
    }

    private func serverNotInstalledRow(_ harness: ServerHarness) -> some View {
        HarnessInstallHintRow(harness: harness)
    }

    /// Refresh = rescan: the server re-resolves its PATH first, so a CLI
    /// installed after server start is picked up without restarting anything.
    private func scan() async {
        isScanning = true
        defer { isScanning = false }
        do {
            serverHarnesses = try await environment.harnessService.rescanHarnesses()
            scanError = nil
        } catch {
            serverHarnesses = []
            scanError = String(describing: error)
        }
    }

    private func setServerHarness(_ id: String, enabled: Bool) async {
        updateServerHarness(id, enabled: enabled)
        do {
            let updated = try await environment.serverClient.setHarnessEnabled(id: id, enabled: enabled)
            replaceServerHarness(updated)
        } catch {
            updateServerHarness(id, enabled: !enabled)
        }
    }

    private func updateServerHarness(_ id: String, enabled: Bool) {
        guard let index = serverHarnesses.firstIndex(where: { $0.id == id }) else { return }
        serverHarnesses[index].enabled = enabled
    }

    private func replaceServerHarness(_ harness: ServerHarness) {
        guard let index = serverHarnesses.firstIndex(where: { $0.id == harness.id }) else { return }
        serverHarnesses[index] = harness
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
