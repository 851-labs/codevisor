import Foundation

extension ProjectListModel {
    /// Picks the most recently used real project on one machine while keeping
    /// the fleet-wide ordering shared with the run-target picker.
    public func firstNonScratchProject(
        on serverId: String,
        byWorkspaceRecency workspaces: [Workspace]
    ) -> Project? {
        fleetActiveProjectsByWorkspaceRecency(workspaces).first {
            $0.serverId == serverId && !$0.isScratch
        }
    }
}
