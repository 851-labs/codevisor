struct ActiveWorkspaceActions {
  let name: String
  let pin: WorkspacePin?
  let rename: @MainActor () -> Void
  let archive: @MainActor () -> Void
}
