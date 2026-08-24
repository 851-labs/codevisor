import Foundation

/// Environment surface split from the class body to keep
/// AppEnvironment.swift within size limits.
extension AppEnvironment {
    public var harnessService: any HarnessServicing {
        harnessService(for: machines.selectedMachineId)
    }

    public var sessionImporter: SessionImporter {
        SessionImporter(harnessService: harnessService)
    }

    /// True while an app self-update or a selected-server update is installing.
    /// Drives the composer lock so no new turn starts during the restart.
    public var isUpdateInProgress: Bool {
        appUpdate.isUpdating || machines.serverUpdatePhase == .updating
    }

    /// A machine's harness lifecycle changed (install/update progress): the
    /// catalog consumers invalidate, and the update center re-reads that
    /// machine's inventory so its rows track the operation.
    func noteHarnessLifecycle(onServer serverId: String) {
        harnessCatalogDidChange(onServer: serverId)
        updateCenter.noteHarnessLifecycleChanged(onServer: serverId)
    }

    /// Changes update channels immediately; the Settings view follows this
    /// with a fresh check so the state updates without a relaunch. The
    /// channel is FLEET state: it replicates through the config plane so
    /// every machine — and every other client — follows.
    public func setAlphaUpdatesEnabled(_ enabled: Bool) {
        settings.setAlphaUpdatesEnabled(enabled)
        appUpdate.setAllowsAlphaUpdates(enabled)
        machines.serverUpdateChannel = enabled ? .alpha : .stable
        configSync.set(
            namespace: "settings",
            key: "updateChannel",
            value: .string(enabled ? "alpha" : "stable")
        )
        Task { [machines] in
            await machines.refreshStatus(for: machines.selectedMachineId)
        }
    }

    /// Applies remotely-synced settings to this client. Loop-safe: local
    /// state changes only when it actually differs, and nothing here writes
    /// back into the replica.
    func applySyncedSettings() {
        guard
            case let .string(channel)? = configSync.value(
                namespace: "settings",
                key: "updateChannel"
            )
        else { return }
        let alpha = channel == "alpha"
        guard alpha != settings.alphaUpdatesEnabled else { return }
        settings.setAlphaUpdatesEnabled(alpha)
        appUpdate.setAllowsAlphaUpdates(alpha)
        machines.serverUpdateChannel = alpha ? .alpha : .stable
    }
}
