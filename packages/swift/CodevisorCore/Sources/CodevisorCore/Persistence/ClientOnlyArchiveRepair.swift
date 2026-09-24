//  One-time repair for workspaces this client archived but never told the
//  server about.
//
//  Archiving a workspace wrote the flag locally and then fired the upload
//  without a marker, a retry, or any record that it still owed one. For a
//  workspace the server had never seen (`isServerSynced == false`) nothing
//  reconciled it in either direction afterwards, so the flag sat there
//  permanently — hiding the workspace AND every chat in it on this machine
//  while every other client kept showing them. That is one of the two shapes
//  behind "some of my clients don't show chats that others do".
//
//  The archive can no longer be confirmed: there is no server row to confirm
//  it against. Revealing the workspace again is the recoverable direction —
//  the user can archive it once more, and this time it will reach the server.

import Foundation

public enum ClientOnlyArchiveRepair {
  public static let key = "client-only-archive-repair-v1"

  /// Returns whether the repair ran.
  @discardableResult
  public static func runIfNeeded(workspaces: any WorkspaceRepository) -> Bool {
    guard !workspaces.hasPerformedMigration(key) else { return false }
    for workspace in workspaces.loadAll()
    where workspace.isArchived && !workspace.isServerSynced {
      var revealed = workspace
      revealed.isArchived = false
      workspaces.save(revealed)
    }
    workspaces.markMigrationPerformed(key)
    return true
  }
}
