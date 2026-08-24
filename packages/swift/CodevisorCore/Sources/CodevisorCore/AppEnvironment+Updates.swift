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
}
