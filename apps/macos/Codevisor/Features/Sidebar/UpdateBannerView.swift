import SwiftUI
import CodevisorCore

/// The "new version available" banner pinned to the top of the sidebar.
/// Non-modal and dismissible per HIG: it states what's available, offers a
/// single clear action, and can be put off until the next release.
struct UpdateBannerView: View {
    var model: AppUpdateModel
    let release: AppUpdateRelease
    /// Blocks the install while chats are still running: replacing the app
    /// (and restarting the bundled server) mid-turn would kill live work.
    var hasRunningChats: Bool = false
    @Environment(\.theme) private var theme

    private static let runningChatsHint = "Update once all of your chats are finished."

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Update Available")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if model.isUpdating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(model.failureMessage == nil ? "Update" : "Try Again") {
                        Task { await model.installUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(hasRunningChats)
                    .help(hasRunningChats ? Self.runningChatsHint : "")
                    .tooltip(hasRunningChats ? Self.runningChatsHint : "")
                }
            }

            if let message = model.failureMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let page = release.releasePageURL {
                    Link("View Release", destination: page)
                        .font(.caption)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.cardBackground)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Codevisor \(release.version) is available")
    }
}

/// Banner shown when the connected remote machine's server has a newer
/// release available. Triggering it asks that server to update itself and
/// waits for it to come back.
struct ServerUpdateBannerView: View {
    var machines: MachineController
    let machine: CodevisorMachine
    let update: ServerUpdateInfo
    /// Blocks the remote update while chats are still running on that machine:
    /// the server restarts to apply it, which would kill live turns.
    var hasRunningChats: Bool = false
    @Environment(\.theme) private var theme

    private static let runningChatsHint = "Update once all of the chats on this machine are finished."

    private var isUpdating: Bool { machines.serverUpdatePhase == .updating }

    private var failureMessage: String? {
        if case let .failed(message) = machines.serverUpdatePhase { return message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Text("Server Update Available")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 8)
                if isUpdating {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Button(failureMessage == nil ? "Update" : "Try Again") {
                        Task { await machines.updateSelectedServer() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(hasRunningChats)
                    .help(hasRunningChats ? Self.runningChatsHint : "")
                    .tooltip(hasRunningChats ? Self.runningChatsHint : "")
                }
            }

            if let failureMessage {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(theme.cardBackground)
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Server update \(update.latestVersion) is available for \(machine.name)")
    }
}

#Preview("Update available") {
    let model = AppUpdateModel(currentVersion: "0.1.0", checker: DisabledUpdateChecker())
    return UpdateBannerView(
        model: model,
        release: AppUpdateRelease(version: "0.2.0")
    )
    .padding()
    .frame(width: 280)
}
