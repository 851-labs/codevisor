import Foundation

/// Update-related surface of the environment, split from the class body to
/// keep AppEnvironment.swift within size limits.
extension AppEnvironment {
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
}
