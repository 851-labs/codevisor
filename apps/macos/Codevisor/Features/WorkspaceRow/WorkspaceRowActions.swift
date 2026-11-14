import CodevisorUI

struct WorkspaceRowActions {
  let pin: WorkspacePin?
  let rename: () -> Void
  let archive: () -> Void
  var sectionMenu: MoveToSectionMenu? = nil
  var noun = "workspace"

  func renaming(after action: @escaping () -> Void) -> WorkspaceRowActions {
    WorkspaceRowActions(
      pin: pin,
      rename: {
        action()
        rename()
      },
      archive: archive, sectionMenu: sectionMenu, noun: noun)
  }
}
