import CodevisorCore
import CodevisorUI
import SwiftUI
import os

/// One machine's harness picture, rendered on its page: the
/// installed harnesses THERE (sign-in, updates, enable), rescan and custom
/// entries, and the not-yet-installed catalog with install hints. Installs
/// and sign-ins are genuinely per machine — this pane never pretends
/// otherwise.
struct HarnessMachinePane: View {
    /// A failed enable/disable toggle, pending display in an alert.
    private struct ToggleError: Identifiable {
        let id = UUID()
        let title: String
        let message: String
    }

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme
    let machine: CodevisorMachine

    @State private var serverHarnesses: [ServerHarness] = []
    @State private var isScanning = true
    @State private var scanError: String?
    @State private var toggleError: ToggleError?
    @State private var authenticationHarness: ServerHarness?
    @State private var detailHarness: ServerHarness?
    @State private var showsCustomEditor = false
    @State private var editingCustomHarnessId: String?
    /// Bridges the button click to the server's returned lifecycle snapshot;
    /// otherwise the row can briefly fall back to Update after the 202 ack.
    @State private var startingHarnessIds: Set<String> = []

    private var serverId: String { machine.id }
    private var serverInstalled: [ServerHarness] { serverHarnesses.filter(\.isReady) }
    private var serverNotInstalled: [ServerHarness] { serverHarnesses.filter { !$0.isReady } }

    var body: some View {
        Group {
            installedSection
                .task(id: serverId) { await scan() }
                .onChange(of: environment.harnessCatalogRevision(for: serverId)) { _, _ in
                    // A lifecycle event (update detected, install finished) or another
                    // pane changed the catalog — refetch the light list, no PATH scan.
                    Task { await refreshList() }
                }
                .onChange(of: serverHarnesses) { previous, current in
                    // Continue the user's intent: an install they just started that
                    // finished and needs sign-in opens the auth sheet directly.
                    guard authenticationHarness == nil else { return }
                    for harness in current where harness.isReady {
                        let before = previous.first { $0.id == harness.id }
                        guard before?.lifecycle?.phase == "installing", before?.isReady != true,
                            harness.auth != nil, !canUse(harness)
                        else { continue }
                        authenticationHarness = harness
                        break
                    }
                }
                .sheet(item: $authenticationHarness) { harness in
                    HarnessAuthenticationView(harness: harness) { replaceServerHarness($0) }
                }
                .sheet(item: $detailHarness) { harness in
                    HarnessDetailSheet(harness: harness)
                }
                .sheet(isPresented: $showsCustomEditor) {
                    CustomHarnessEditorSheet(editingId: editingCustomHarnessId) { harnesses in
                        serverHarnesses = harnesses
                        environment.harnessCatalogDidChange(onServer: serverId)
                    }
                }
                .alert(
                    toggleError?.title ?? "",
                    isPresented: Binding(
                        get: { toggleError != nil },
                        set: { if !$0 { toggleError = nil } }
                    ),
                    presenting: toggleError
                ) { _ in
                    Button("OK") {}
                        .settingsActionTint(theme)
                } message: { error in
                    Text(error.message)
                }
            if !serverNotInstalled.isEmpty {
                Section("Not installed") {
                    ForEach(serverNotInstalled, id: \.id) { harness in
                        serverNotInstalledRow(harness)
                    }
                }
            }
        }
        .environment(\.settingsMachineId, machine.id)
    }

    /// The always-present section; it carries the pane's lifecycle
    /// modifiers (task, sheets, alert) exactly once — a Group would apply
    /// them to every section.
    private var installedSection: some View {
        Section {
            if isScanning, serverHarnesses.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for harnesses…").foregroundStyle(.secondary)
                }
            } else if scanError != nil {
                // Unreachable is not "nothing installed" — say so.
                Text("Couldn't reach this machine's server. Check its status, then refresh.")
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
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button {
                    Task { await scan() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .settingsActionTint(theme)
                .disabled(isScanning)
                Button("Add Custom Harness…") {
                    editingCustomHarnessId = nil
                    showsCustomEditor = true
                }
                .settingsActionTint(theme)
            }
            .font(.body)
        }
    }

    private func serverInstalledRow(_ harness: ServerHarness) -> some View {
        HStack(spacing: 10) {
            HStack(spacing: 10) {
                HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 15)
                    .foregroundStyle(.secondary)
                    .frame(width: 20)
                VStack(alignment: .leading, spacing: 2) {
                    Text(harness.name)
                    Text(rowSubtitle(harness))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .truncationMode(.tail)
                        .help(rowSubtitle(harness))
                }
            }
            Spacer()
            if harness.auth != nil && !canUse(harness) {
                // Sign-in is the row's one call to action — the update offer
                // waits until the harness is usable.
                Button("Sign In…") { authenticationHarness = harness }
                    .settingsActionTint(theme)
            } else {
                if startingHarnessIds.contains(harness.id) || harness.lifecycle?.phase == "updating" {
                    ProgressView()
                        .controlSize(.small)
                        .help("Updating \(harness.name)…")
                } else if harness.lifecycle?.phase == "pendingUpdate" {
                    Text("Queued")
                        .foregroundStyle(.secondary)
                        .help("Updates when active \(harness.name) chats finish")
                } else if harness.updateInfo?.updateAvailable == true {
                    Button(harness.lifecycle?.phase == "failed" ? "Try Again" : "Update") {
                        Task { await updateHarness(harness) }
                    }
                    .settingsActionTint(theme)
                    .help(updateHelp(harness))
                }
                Toggle(
                    "Enable \(harness.name)",
                    isOn: Binding(
                        get: { harness.enabled },
                        set: { enabled in Task { await setServerHarness(harness.id, enabled: enabled) } }
                    )
                )
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }
            rowMenu(harness)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    /// The row's secondary actions, collapsed behind one quiet control so
    /// rows stay scannable: Get Info, Manage Accounts, Edit (custom).
    private func rowMenu(_ harness: ServerHarness) -> some View {
        Menu {
            if harness.source == "custom" {
                Button("Edit…") {
                    editingCustomHarnessId = harness.id
                    showsCustomEditor = true
                }
            } else {
                Button("Get Info…") { detailHarness = harness }
            }
            if harness.auth != nil {
                Button("Manage Accounts…") { authenticationHarness = harness }
            }
        } label: {
            Image(systemName: "ellipsis.circle")
                .foregroundStyle(.secondary)
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("\(harness.name) options")
        .accessibilityLabel("\(harness.name) options")
    }

    private func canUse(_ harness: ServerHarness) -> Bool {
        harness.auth?.state == "authenticated" || harness.auth?.state == "notRequired"
    }

    /// Auth status, replaced by live update progress/failure when relevant.
    /// A plain "update available" never rides here — the Update button IS
    /// that signal.
    private func rowSubtitle(_ harness: ServerHarness) -> String {
        if harness.lifecycle?.phase == "updating" {
            let target = harness.lifecycle?.targetVersion
            return target.map { "Updating to \($0)…" } ?? "Updating…"
        }
        if harness.lifecycle?.phase == "failed" {
            let reason = harness.lifecycle?.error?
                .split(whereSeparator: \.isNewline).first.map(String.init)
            return reason.map { "Update failed: \($0)" } ?? "Update failed"
        }
        return authStatus(harness)
    }

    private func updateHelp(_ harness: ServerHarness) -> String {
        guard let update = harness.updateInfo, let latest = update.latestVersion else {
            return "Update \(harness.name)"
        }
        let installed = update.installedVersion.map { "\($0) → " } ?? ""
        return "Update \(harness.name) (\(installed)\(latest))"
    }

    private func updateHarness(_ harness: ServerHarness) async {
        startingHarnessIds.insert(harness.id)
        defer { startingHarnessIds.remove(harness.id) }
        do {
            let started = try await environment.machines.client(for: serverId)
                .updateHarness(id: harness.id)
            if let lifecycle = started.lifecycle,
                let index = serverHarnesses.firstIndex(where: { $0.id == harness.id })
            {
                serverHarnesses[index].lifecycle = lifecycle
                environment.setHarnessLifecycle(
                    lifecycle,
                    harnessId: harness.id,
                    onServer: serverId
                )
            } else {
                // Older servers do not return the lifecycle in the 202 body.
                // Keep the local spinner visible through the fallback fetch.
                await refreshList()
            }
            environment.harnessCatalogDidChange(onServer: serverId)
        } catch {
            toggleError = ToggleError(
                title: "Couldn't update \(harness.name)",
                message: error.localizedDescription
            )
        }
    }

    private func authStatus(_ harness: ServerHarness) -> String {
        guard let auth = harness.auth else { return "Sign-in status unavailable" }
        let account = auth.accounts.first(where: { $0.id == auth.activeAccountId }) ?? auth.accounts.first
        switch auth.state {
        case "authenticated": return account?.email.map { "Signed in as \($0)" } ?? "Signed in"
        case "notRequired": return "No sign-in required"
        case "checking": return "Checking sign-in…"
        case "expired": return "Sign-in expired"
        // Plain language, never the probe's `detail` — that carries a crashed
        // CLI's stderr. The cause is summarized and persisted server-side.
        case "error": return "Something went wrong starting the CLI"
        default: return "Not signed in"
        }
    }

    @ViewBuilder
    private func serverNotInstalledRow(_ harness: ServerHarness) -> some View {
        if harness.source == "custom" {
            // A custom entry whose command wasn't found — keep it editable so
            // a typo'd path is fixable right here.
            HStack(spacing: 10) {
                HarnessInstallHintRow(harness: harness)
                Button("Edit…") {
                    editingCustomHarnessId = harness.id
                    showsCustomEditor = true
                }
                .settingsActionTint(theme)
            }
        } else {
            HarnessInstallHintRow(harness: harness)
        }
    }

    /// Light refetch of the current list (no PATH re-resolve) — used when a
    /// server event invalidated the catalog. Errors keep the current list.
    private func refreshList() async {
        guard let refreshed = try? await environment.harnessService(for: serverId).allHarnesses()
        else { return }
        serverHarnesses = refreshed
        scanError = nil
    }

    /// Refresh = rescan: the server re-resolves its PATH first, so a CLI
    /// installed after server start is picked up without restarting anything.
    private func scan() async {
        isScanning = true
        defer { isScanning = false }
        do {
            serverHarnesses = try await environment.harnessService(for: serverId).rescanHarnesses()
            environment.harnessCatalogDidChange(onServer: serverId)
            scanError = nil
        } catch {
            serverHarnesses = []
            scanError = String(describing: error)
        }
    }

    private func setServerHarness(_ id: String, enabled: Bool) async {
        updateServerHarness(id, enabled: enabled)
        do {
            let updated = try await environment.machines.client(for: serverId)
                .setHarnessEnabled(id: id, enabled: enabled)
            replaceServerHarness(updated)
            environment.harnessCatalogDidChange(onServer: serverId)
        } catch {
            updateServerHarness(id, enabled: !enabled)
            Log.server.error(
                "Setting harness \(id, privacy: .public) enabled=\(enabled, privacy: .public) failed: \(String(describing: error), privacy: .public)"
            )
            let name = serverHarnesses.first(where: { $0.id == id })?.name ?? id
            toggleError = ToggleError(
                title: enabled ? "Couldn't turn on \(name)" : "Couldn't turn off \(name)",
                message: ErrorReporter.userFacingMessage(for: error)
            )
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
