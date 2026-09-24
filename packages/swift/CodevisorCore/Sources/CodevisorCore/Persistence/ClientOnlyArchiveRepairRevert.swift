//  One-time revert of `client-only-archive-repair-v1`.
//
//  That repair un-archived every workspace this client had archived but the
//  server had never seen (`isServerSynced == false`), on the theory that the
//  archive had failed to upload and was hiding chats other clients showed.
//  The theory was wrong: a workspace the server has never seen cannot be
//  showing on any other client. Those records were old local workspaces the
//  user archived on purpose, and the repair resurfaced hundreds of them.
//
//  This pass hides them again. It only runs where the bad repair ran, and it
//  only touches workspaces that are both unsynced and on a machine whose
//  first navigation sync has already completed — past that point an unsynced
//  workspace is a local record that will never reach the server, not one
//  still waiting to be published.

import Foundation

public enum ClientOnlyArchiveRepairRevert {
  public static let key = "client-only-archive-repair-revert-v1"
  /// Receipt left by the repair being reverted. Its presence is the only
  /// evidence that this store had workspaces resurfaced.
  static let revertedRepairKey = "client-only-archive-repair-v1"

  /// Returns whether the revert ran.
  @discardableResult
  public static func runIfNeeded(workspaces: any WorkspaceRepository) -> Bool {
    guard !workspaces.hasPerformedMigration(key) else { return false }
    if workspaces.hasPerformedMigration(revertedRepairKey) {
      for workspace in workspaces.loadAll()
      where !workspace.isArchived && !workspace.isServerSynced
        && workspaces.hasPerformedMigration("persisted-navigation-v1:\(workspace.serverId)")
      {
        var hidden = workspace
        hidden.isArchived = true
        workspaces.save(hidden)
      }
    }
    workspaces.markMigrationPerformed(key)
    return true
  }
}
