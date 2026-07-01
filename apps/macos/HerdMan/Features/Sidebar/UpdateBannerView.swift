import SwiftUI
import HerdManCore

/// The "new version available" banner pinned to the top of the sidebar.
/// Non-modal and dismissible per HIG: it states what's available, offers a
/// single clear action, and can be put off until the next release.
struct UpdateBannerView: View {
    var model: AppUpdateModel
    let release: AppUpdateRelease
    var onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Update Available")
                        .font(.subheadline.weight(.semibold))
                    Text("HerdMan \(release.version)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !model.isUpdating {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Skip this version")
                    .accessibilityLabel("Dismiss update notification")
                }
            }

            if let message = model.failureMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if model.isUpdating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(model.failureMessage == nil ? "Update Now" : "Try Again") {
                        Task { await model.installUpdate() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    if let page = release.releasePageURL, model.failureMessage != nil {
                        Link("View Release", destination: page)
                            .font(.caption)
                    }
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.5))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("HerdMan \(release.version) is available")
    }
}

/// Banner shown when the connected remote machine's server has a newer
/// release available. Triggering it asks that server to update itself and
/// waits for it to come back.
struct ServerUpdateBannerView: View {
    var machines: MachineController
    let machine: HerdManMachine
    let update: ServerUpdateInfo
    var onDismiss: () -> Void

    private var isUpdating: Bool { machines.serverUpdatePhase == .updating }

    private var failureMessage: String? {
        if case let .failed(message) = machines.serverUpdatePhase { return message }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "server.rack")
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Server Update Available")
                        .font(.subheadline.weight(.semibold))
                    Text("\(machine.name): \(update.currentVersion) → \(update.latestVersion)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                if !isUpdating {
                    Button(action: onDismiss) {
                        Image(systemName: "xmark")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Skip this version")
                    .accessibilityLabel("Dismiss server update notification")
                }
            }

            if let failureMessage {
                Text(failureMessage)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                if isUpdating {
                    ProgressView()
                        .controlSize(.small)
                    Text("Updating server…")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Button(failureMessage == nil ? "Update Server" : "Try Again") {
                        Task { await machines.updateSelectedServer() }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                }
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.quaternary.opacity(0.5))
        )
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Server update \(update.latestVersion) is available for \(machine.name)")
    }
}

#Preview("Update available") {
    let model = AppUpdateModel(currentVersion: "0.1.0", checker: DisabledUpdateChecker())
    return UpdateBannerView(
        model: model,
        release: AppUpdateRelease(version: "0.2.0"),
        onDismiss: {}
    )
    .padding()
    .frame(width: 280)
}
