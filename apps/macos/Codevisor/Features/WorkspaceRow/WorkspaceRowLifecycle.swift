enum WorkspaceRowLifecycle {
  case active(WorkspaceRowActions)
  case archived(onRestore: () -> Void)

  var isArchived: Bool {
    if case .archived = self { return true }
    return false
  }
}
