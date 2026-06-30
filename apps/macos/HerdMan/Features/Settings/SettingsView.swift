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

    var body: some View {
        Form {
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
    }
}

/// Harnesses settings — toggle the installed ACP harnesses you want to use,
/// rescan for newly installed ones, and see which known harnesses aren't
/// installed yet.
struct HarnessesSettingsView: View {
    @Environment(AppEnvironment.self) private var environment

    @State private var all: [DiscoveredAgent] = []
    @State private var isScanning = true
    @State private var isImporting = false
    @State private var showsNotInstalled = false

    private var installed: [DiscoveredAgent] { all.filter { $0.readiness.isReady } }
    private var notInstalled: [DiscoveredAgent] { all.filter { !$0.readiness.isReady } }

    var body: some View {
        Form {
            Section {
                if isScanning {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Scanning for harnesses…").foregroundStyle(.secondary)
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

            if !notInstalled.isEmpty {
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

    private func scan() async {
        isScanning = true
        all = await environment.agentService.discoverAllHarnesses()
        isScanning = false
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
