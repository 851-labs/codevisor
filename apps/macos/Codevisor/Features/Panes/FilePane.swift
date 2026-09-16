import CodevisorCore
import CodevisorUI
import SwiftUI

@MainActor
final class FilePane: Pane {
  let id: UUID
  let kind: PaneKind = .document
  var onGroupCommand: ((PaneGroupCommand) -> Void)?
  var onFocusChanged: ((Bool) -> Void)?
  var onNavigate: ((String) -> Void)?
  let model: FilePaneModel

  init(context: PaneContext, descriptor: PaneDescriptorState) {
    id = descriptor.id
    model = FilePaneModel(
      id: descriptor.id, path: descriptor.documentPath ?? "",
      rootPath: context.workspaceRootDirectory ?? context.session?.cwd ?? context.project.folderURL.path,
      machineId: context.machine.id,
      client: context.client ?? CodevisorServerClient(config: context.machine.serverConfig))
    model.onNavigate = { [weak self] path in self?.onNavigate?(path) }
  }

  func makeView() -> AnyView {
    AnyView(FilePaneView(model: model))
  }

  func focus() {}
  func visibilityChanged(_ visible: Bool) {}
  func willDelete() async { model.close() }
  func detach() { model.close() }
}
