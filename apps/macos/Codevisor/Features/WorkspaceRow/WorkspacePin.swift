struct WorkspacePin {
  let isPinned: Bool
  let toggle: @MainActor () -> Void

  var title: String { isPinned ? "Unpin" : "Pin" }
  var systemImage: String { isPinned ? "pin.slash" : "pin" }
}
