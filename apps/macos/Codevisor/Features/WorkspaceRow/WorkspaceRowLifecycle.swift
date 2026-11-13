enum WorkspaceRowLifecycle {
  case active(WorkspaceRowActions)
  case chat(onArchive: () -> Void)
  case archived(onRestore: () -> Void)

  var isArchived: Bool {
    if case .archived = self { return true }
    return false
  }
}
