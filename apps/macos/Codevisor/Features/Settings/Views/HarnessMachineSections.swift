import CodevisorCore
import CodevisorUI
import SwiftUI

/// Pure section and row rendering for a machine's harness catalog.
struct HarnessMachineSections: View {
    @Environment(\.theme) private var theme

    let model: HarnessMachineModel
    let onScan: () -> Void
    let onAuthenticate: (ServerHarness) -> Void
    let onShowDetail: (ServerHarness) -> Void
    let onEditCustom: (String?) -> Void

    var body: some View {
        Group {
            installedSection
            if !model.notInstalledHarnesses.isEmpty {
                Section("Not installed") {
                    ForEach(model.notInstalledHarnesses, id: \.id) { harness in
                        notInstalledRow(harness)
                    }
                }
            }
        }
    }

    private var installedSection: some View {
        Section {
            if model.isScanning, model.harnesses.isEmpty {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Scanning for harnesses…").foregroundStyle(.secondary)
                }
            } else {
                if let error = model.catalogErrorMessage {
                    // A failed refresh keeps the last useful catalog visible.
                    Text("Couldn't refresh this machine's harnesses. Check its status, then try again.")
                        .foregroundStyle(.secondary)
                        .help(error)
                }
                if model.installedHarnesses.isEmpty {
                    Text("No harnesses installed. Install Claude Code, Codex, or another ACP agent, then rescan.")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(model.installedHarnesses, id: \.id) { harness in
                        installedRow(harness)
                    }
                }
            }
        } header: {
            Text("Installed")
        } footer: {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                Button(action: onScan) {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .settingsActionTint(theme)
                .disabled(model.isScanning)
                Button("Add Custom Harness…") { onEditCustom(nil) }
                    .settingsActionTint(theme)
            }
            .font(.body)
        }
    }

    private func installedRow(_ harness: ServerHarness) -> some View {
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
            primaryAction(harness)
            Toggle(
                "Enable \(harness.name)",
                isOn: Binding(
                    get: { model.harness(id: harness.id)?.isDesiredEnabled ?? harness.isDesiredEnabled },
                    set: { enabled in
                        Task { await model.setDesiredEnabled(id: harness.id, enabled: enabled) }
                    }
                )
            )
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .disabled(model.isChangingPreference(for: harness.id))
            rowMenu(harness)
        }
        .frame(maxWidth: .infinity, alignment: .trailing)
    }

    @ViewBuilder
    private func primaryAction(_ harness: ServerHarness) -> some View {
        if harness.requiresAuthentication {
            // Sign-in and fleet enablement are independent controls.
            Button("Sign In…") { onAuthenticate(harness) }
                .settingsActionTint(theme)
        } else if model.isStartingUpdate(for: harness.id) || harness.lifecycle?.resolvedPhase == .updating {
            ProgressView()
                .controlSize(.small)
                .help("Updating \(harness.name)…")
        } else if harness.lifecycle?.resolvedPhase == .pendingUpdate {
            Text("Queued")
                .foregroundStyle(.secondary)
                .help("Updates when active \(harness.name) chats finish")
        } else if harness.updateInfo?.updateAvailable == true {
            Button(harness.lifecycle?.resolvedPhase == .failed ? "Try Again" : "Update") {
                Task { await model.updateHarness(id: harness.id) }
            }
            .settingsActionTint(theme)
            .help(updateHelp(harness))
        }
    }

    /// The row's secondary actions stay behind one quiet control.
    private func rowMenu(_ harness: ServerHarness) -> some View {
        Menu {
            if harness.source == "custom" {
                Button("Edit…") { onEditCustom(harness.id) }
            } else {
                Button("Get Info…") { onShowDetail(harness) }
            }
            if harness.auth != nil {
                Button("Manage Accounts…") { onAuthenticate(harness) }
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

    private func rowSubtitle(_ harness: ServerHarness) -> String {
        if harness.lifecycle?.resolvedPhase == .updating {
            let target = harness.lifecycle?.targetVersion
            return target.map { "Updating to \($0)…" } ?? "Updating…"
        }
        if harness.lifecycle?.resolvedPhase == .failed {
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

    private func authStatus(_ harness: ServerHarness) -> String {
        guard let auth = harness.auth else { return "Sign-in status unavailable" }
        let account = auth.accounts.first(where: { $0.id == auth.activeAccountId }) ?? auth.accounts.first
        switch auth.resolvedState {
        case .authenticated: return account?.email.map { "Signed in as \($0)" } ?? "Signed in"
        case .notRequired: return "No sign-in required"
        case .checking: return "Checking sign-in…"
        case .expired: return "Sign-in expired"
        case .error: return "Something went wrong starting the CLI"
        case .unauthenticated, .unavailable, .unknown: return "Not signed in"
        }
    }

    @ViewBuilder
    private func notInstalledRow(_ harness: ServerHarness) -> some View {
        if harness.source == "custom" {
            HStack(spacing: 10) {
                HarnessInstallHintRow(harness: harness)
                Button("Edit…") { onEditCustom(harness.id) }
                    .settingsActionTint(theme)
            }
        } else {
            HarnessInstallHintRow(harness: harness)
        }
    }
}
