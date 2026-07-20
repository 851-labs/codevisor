import SwiftUI
import CodevisorCore

/// Slim update banner for the *selected* harness, shown with the composer:
/// "Codex 0.145.0 is available · Update · ✕". Follows the UpdateBannerView
/// idiom — non-modal, one clear action, dismissible per version. Only ever
/// about the harness the user is actually chatting with; other harnesses
/// surface in Settings.
struct HarnessUpdateBannerView: View {
    @Bindable var controller: SessionController
    /// Blocks the immediate update while chats on this harness are mid-turn;
    /// the when-idle flow replaces this with queueing.
    var hasRunningChats: Bool = false

    @Environment(AppEnvironment.self) private var environment
    @Environment(\.theme) private var theme

    @State private var isStarting = false
    @State private var startError: String?
    /// Version string the user dismissed, remembered per harness so the
    /// banner returns only when something newer appears.
    @AppStorage private var dismissedVersion: String

    init(controller: SessionController, hasRunningChats: Bool = false) {
        self.controller = controller
        self.hasRunningChats = hasRunningChats
        _dismissedVersion = AppStorage(
            wrappedValue: "",
            "harnessUpdateDismissed.\(controller.activeHarnessId ?? "none")"
        )
    }

    private static let runningChatsHint = "Update once your chats on this agent are finished."

    /// Update knowledge comes from the environment's lifecycle cache, which
    /// is fetched separately from the picker's plain harness list — the
    /// picker stays snappy, the banner appears when the cache lands.
    private var harness: ServerHarness? {
        guard let id = controller.activeHarnessId else { return nil }
        return environment.harnessLifecycle(for: environment.machines.selectedMachineId)
            .first { $0.id == id }
    }

    private var latestVersion: String? { harness?.updateInfo?.latestVersion }

    private var isQueued: Bool { harness?.lifecycle?.phase == "pendingUpdate" }

    private var isVisible: Bool {
        guard let harness else { return false }
        if isQueued { return true }
        guard let latestVersion,
              harness.updateInfo?.updateAvailable == true,
              latestVersion != dismissedVersion
        else { return false }
        return true
    }

    private var isUpdating: Bool {
        harness?.lifecycle?.phase == "updating" || isStarting
    }

    var body: some View {
        if let harness, isVisible {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    HarnessIcon(harnessId: harness.id, fallbackSymbolName: harness.symbolName, size: 13)
                        .foregroundStyle(.secondary)
                    Text(
                        isQueued
                            ? "Update queued — installs when your \(harness.name) chats finish"
                            : "\(harness.name) \(latestVersion ?? "") is available"
                    )
                    .font(.subheadline)
                    Spacer(minLength: 8)
                    if isUpdating {
                        ProgressView()
                            .controlSize(.small)
                    } else if isQueued {
                        Button("Update Now") {
                            Task { await applyPending(harness.id) }
                        }
                        .controlSize(.small)
                        .help("Install without waiting for chats to finish — running chats keep the previous version until restarted")
                        Button("Cancel") {
                            Task { await cancelPending(harness.id) }
                        }
                        .controlSize(.small)
                    } else {
                        Button(failureMessage == nil ? "Update" : "Try Again") {
                            Task { await update(harness.id) }
                        }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.small)
                        .help(hasRunningChats ? Self.runningChatsHint : "")
                        .accessibilityHint(hasRunningChats ? Self.runningChatsHint : "")
                        Button {
                            dismissedVersion = latestVersion ?? ""
                        } label: {
                            Image(systemName: "xmark")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Dismiss until the next version")
                        .accessibilityLabel("Dismiss update notice")
                    }
                }
                if let failureMessage {
                    Text(failureMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(theme.cardBackground))
            .themedCardShadow(theme)
            .accessibilityElement(children: .contain)
            .accessibilityLabel(
                isQueued
                    ? "\(harness.name) update queued until chats finish"
                    : "\(harness.name) update \(latestVersion ?? "") is available"
            )
        }
    }

    private var failureMessage: String? {
        startError ?? (harness?.lifecycle?.phase == "failed" ? harness?.lifecycle?.error : nil)
    }

    private func update(_ harnessId: String) async {
        isStarting = true
        startError = nil
        defer { isStarting = false }
        let serverId = environment.machines.selectedMachineId
        do {
            _ = try await environment.machines.client(for: serverId).updateHarness(id: harnessId)
            environment.harnessCatalogDidChange(onServer: serverId)
        } catch {
            startError = error.localizedDescription
        }
    }

    private func applyPending(_ harnessId: String) async {
        startError = nil
        let serverId = environment.machines.selectedMachineId
        do {
            try await environment.machines.client(for: serverId).applyPendingHarnessUpdate(id: harnessId)
            environment.harnessCatalogDidChange(onServer: serverId)
        } catch {
            startError = error.localizedDescription
        }
    }

    private func cancelPending(_ harnessId: String) async {
        startError = nil
        let serverId = environment.machines.selectedMachineId
        do {
            try await environment.machines.client(for: serverId).cancelPendingHarnessUpdate(id: harnessId)
            environment.harnessCatalogDidChange(onServer: serverId)
        } catch {
            startError = error.localizedDescription
        }
    }
}
