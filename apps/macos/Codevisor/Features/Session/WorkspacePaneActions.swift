import CodevisorCore
import CodevisorUI
import SwiftUI

struct WorkspacePaneActions: ViewModifier {
  let pluginAppPresenter: PluginAppPresenter?
  let openFileDocument: OpenFileDocumentAction
  let openSubagent: OpenSubagentAction

  func body(content: Content) -> some View {
    content
      .environment(\.pluginAppPresenter, pluginAppPresenter)
      .environment(\.openFileDocument, openFileDocument)
      .environment(\.openSubagent, openSubagent)
  }
}
