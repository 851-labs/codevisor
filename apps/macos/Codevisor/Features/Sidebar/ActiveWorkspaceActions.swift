struct ActiveWorkspaceActions {
  let name: String
  let isPinned: Bool
  let rename: @MainActor () -> Void
  let togglePin: @MainActor () -> Void
  let fork: (@MainActor () -> Void)?
  let archive: @MainActor () -> Void
}
