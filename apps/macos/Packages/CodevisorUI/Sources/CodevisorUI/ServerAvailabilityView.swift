import CodevisorCore
import SwiftUI

/// The shared detail-area state used while a machine's server is starting,
/// reconnecting, or migrating. Keeping this at the navigation boundary means
/// cached sidebars/lists stay useful without mounting views that would issue
/// requests before the server is ready.
public struct ServerAvailabilityView: View {
    private let machineId: String
    private let availability: ServerAvailability
    private let machineName: String
    private let isLocal: Bool
    private let dataUpgradeProgress: LocalDataUpgradeProgress?
    private let appUpdateInProgress: Bool
    private let retry: () -> Void

    public init(
        machineId: String,
        availability: ServerAvailability,
        machineName: String,
        isLocal: Bool,
        dataUpgradeProgress: LocalDataUpgradeProgress? = nil,
        appUpdateInProgress: Bool = false,
        retry: @escaping () -> Void
    ) {
        self.machineId = machineId
        self.availability = availability
        self.machineName = machineName
        self.isLocal = isLocal
        self.dataUpgradeProgress = dataUpgradeProgress
        self.appUpdateInProgress = appUpdateInProgress
        self.retry = retry
    }

    public var body: some View {
        DelayedServerStatus(revealAfterDelay: isActivelyWaiting) {
            VStack(spacing: 18) {
                if isFailed {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 38, weight: .medium))
                        .foregroundStyle(.orange)
                } else {
                    ProgressView(value: progressFraction)
                        .progressViewStyle(.circular)
                        .controlSize(.large)
                }

                VStack(spacing: 7) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                        .multilineTextAlignment(.center)

                    Text(message)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .frame(maxWidth: 440)
                }

                if let dataUpgradeProgress,
                   dataUpgradeProgress.state == "running",
                   dataUpgradeProgress.total > 0 {
                    VStack(spacing: 6) {
                        ProgressView(
                            value: Double(dataUpgradeProgress.completed),
                            total: Double(dataUpgradeProgress.total)
                        )
                        Text("\(dataUpgradeProgress.completed) of \(dataUpgradeProgress.total)")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: 320)
                }

                if isFailed {
                    Button("Try Again", action: retry)
                        .buttonStyle(.borderedProminent)
                }
            }
        }
        .id(ServerStatusPresentationID(machineId: machineId, isWaiting: isActivelyWaiting))
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
        .accessibilityElement(children: .contain)
    }

    private var activeMigration: LocalDataUpgradeProgress? {
        guard let dataUpgradeProgress,
              dataUpgradeProgress.state == "running" || dataUpgradeProgress.state == "failed"
        else { return nil }
        return dataUpgradeProgress
    }

    private var progressFraction: Double? {
        activeMigration?.state == "running" ? activeMigration?.fractionCompleted : nil
    }

    private var isFailed: Bool {
        if appUpdateInProgress { return false }
        if activeMigration?.state == "failed" { return true }
        if case .failed = availability { return true }
        return false
    }

    /// Keep fast startup/reconnects visually quiet. Requests are gated for the
    /// entire wait, but the explanatory progress UI only appears when the wait
    /// lasts long enough to be useful.
    private var isActivelyWaiting: Bool {
        if appUpdateInProgress { return true }
        if activeMigration?.state == "running" { return true }
        if case .waiting = availability { return true }
        return false
    }

    private var title: String {
        if appUpdateInProgress { return "Updating Codevisor" }
        if let migration = activeMigration {
            return migration.state == "failed" ? "Server Data Update Failed" : "Updating Server Data"
        }
        return switch availability {
        case let .waiting(reason):
            switch reason {
            case .starting: isLocal ? "Starting Codevisor Server" : "Connecting to Server"
            case .connecting: "Connecting to \(machineName)"
            case .updating: "Updating Codevisor Server"
            case .restarting: "Restarting Codevisor Server"
            }
        case .ready:
            "Server Ready"
        case .failed:
            "Can't Reach \(machineName)"
        }
    }

    private var message: String {
        if appUpdateInProgress {
            return "Codevisor is installing an update and will reopen automatically."
        }
        if let migration = activeMigration {
            if migration.state == "failed" {
                return migration.error ?? "Codevisor couldn't finish updating the server's data."
            }
            return migration.name.isEmpty
                ? "Your cached workspaces are safe. Codevisor will continue when the update finishes."
                : "\(migration.name)\nYour cached workspaces are safe. Codevisor will continue automatically."
        }
        return switch availability {
        case let .waiting(reason):
            switch reason {
            case .starting:
                "Your cached workspaces are still available. This page will open when the server is ready."
            case .connecting:
                "Waiting for the server to become available. This page will open automatically."
            case .updating:
                "The server is installing an update. Codevisor will reconnect automatically."
            case .restarting:
                "The server is restarting. Codevisor will reconnect automatically."
            }
        case .ready:
            "Codevisor is ready."
        case let .failed(message):
            message
        }
    }
}

private struct ServerStatusPresentationID: Hashable {
    let machineId: String
    let isWaiting: Bool
}

private struct DelayedServerStatus<Content: View>: View {
    let revealAfterDelay: Bool
    let content: Content

    @State private var hasPassedDelay = false

    init(revealAfterDelay: Bool, @ViewBuilder content: () -> Content) {
        self.revealAfterDelay = revealAfterDelay
        self.content = content()
    }

    var body: some View {
        ZStack {
            Color.clear

            if !revealAfterDelay || hasPassedDelay {
                content
            }
        }
        .task {
            guard revealAfterDelay else { return }
            do {
                try await Task.sleep(for: .milliseconds(500))
            } catch {
                return
            }
            hasPassedDelay = true
        }
    }
}

/// Whole-window startup state for the client database. Unlike server waiting,
/// no app content is mounted because repositories cannot safely open until
/// this work completes.
public struct ClientDataStartupView: View {
    public init() {}

    public var body: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            VStack(spacing: 7) {
                Text("Preparing Codevisor")
                    .font(.title2.weight(.semibold))
                Text("Checking and updating this device's local data…")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.background)
    }
}
