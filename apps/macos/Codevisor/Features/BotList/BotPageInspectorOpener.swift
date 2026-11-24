import AppKit
import CodevisorCore
import CodevisorUI

struct BotPageInspectorOpener {
  let workspace: Workspace
  let environment: AppEnvironment
  let store: SessionStore
  let fileOpener: FileOpener?

  func open(_ destination: WorkspaceInspectorView.Destination) {
    switch destination {
    case let .pullRequest(url), let .link(url):
      DefaultBrowser.open(url)
    case let .file(path), let .previewFile(path):
      preview(path)
    case .botTranscript:
      presentTranscript()
    case let .toolCall(sessionId, toolCallId):
      store.controllers[SessionStore.SessionKey(serverId: workspace.serverId, sessionId: sessionId)]?
        .revealToolCall(toolCallId)
    case .fileRenamed:
      break
    }
  }

  private func preview(_ target: String) {
    fileOpener?.open(ViewableFile(PreviewFile(serverPath: target)))
  }

  private func presentTranscript() {
    guard let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId) else { return }

    BotTranscriptWindows.shared.present(bot, workspace: workspace, store: store, environment: environment)
  }
}
