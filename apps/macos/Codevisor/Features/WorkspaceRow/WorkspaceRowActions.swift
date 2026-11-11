import CodevisorUI

struct WorkspaceRowActions {
  let isPinned: Bool
  let togglePin: () -> Void
  let rename: () -> Void
  let archive: () -> Void
  var sectionMenu: MoveToSectionMenu? = nil

  func renaming(after action: @escaping () -> Void) -> WorkspaceRowActions {
    WorkspaceRowActions(
      isPinned: isPinned, togglePin: togglePin,
      rename: {
        action()
        rename()
      },
      archive: archive, sectionMenu: sectionMenu)
  }
}
