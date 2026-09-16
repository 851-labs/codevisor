import CodevisorCore
import CodevisorUI
import SwiftUI

extension WorkspaceScreen {
  var activeFileModel: FilePaneModel? {
    guard let pane = activePane, pane.kind == .document else { return nil }
    return filePaneModel(for: pane)
  }

  func filePaneModel(for pane: PaneDescriptorState) -> FilePaneModel {
    let model = FilePaneCache.shared.model(for: pane.id) {
      FilePaneModel(
        id: pane.id, path: pane.documentPath ?? "", rootPath: workspaceCwd,
        machineId: resolvedServerId, client: environment.machines.client(for: resolvedServerId))
    }
    if let path = pane.documentPath, path != model.path { model.navigate(to: path, notify: false) }
    model.onNavigate = { navigateFile(pane, to: $0) }
    return model
  }

  func openFiles(_ source: PaneDescriptorState) {
    var state = panes
    guard let index = state.panes.firstIndex(where: { $0.id == source.id }) else { return }
    let path = workspaceCwd + "/"
    let pane = PaneDescriptorState(
      id: source.id, kind: .document, name: FileDocumentLocation.name(path), terminalKey: source.terminalKey,
      documentPath: path)
    state.panes[index] = pane
    paneBinding.wrappedValue = state
    publishPane(pane)
  }

  func openFileDocument(_ target: String) -> Bool {
    guard let path = FileDocumentLocation.resolve(target, relativeTo: workspaceCwd) else { return false }
    if let existing = panes.panes.first(where: { $0.kind == .document && $0.documentPath == path }) {
      if let line = FileDocumentLocation.line(target) { filePaneModel(for: existing).editor.goToLine(line) }
      select(existing)
      return true
    }
    let id = UUID()
    let pane = PaneDescriptorState(
      id: id, kind: .document, name: FileDocumentLocation.name(path), terminalKey: id.uuidString, documentPath: path)
    var state = panes
    state.panes.append(pane)
    state.selectedPaneId = id
    paneBinding.wrappedValue = state
    publishPane(pane)
    if let line = FileDocumentLocation.line(target) { filePaneModel(for: pane).editor.goToLine(line) }
    return true
  }

  func navigateFile(_ pane: PaneDescriptorState, to path: String) {
    var state = panes
    guard let index = state.panes.firstIndex(where: { $0.id == pane.id }) else { return }
    state.panes[index].documentPath = path
    state.panes[index].name = FileDocumentLocation.name(path)
    paneBinding.wrappedValue = state
    publishPane(state.panes[index])
  }
}
