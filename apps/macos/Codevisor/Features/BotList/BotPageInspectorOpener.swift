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
      revealToolCall(toolCallId, inChat: sessionId)
    case .fileRenamed:
      break
    }
  }

  private func revealToolCall(_ toolCallId: String, inChat sessionId: UUID) {
    let chat = environment.projectList.chat(sessionId, preferring: workspace.serverId)
    let key = SessionStore.SessionKey(serverId: chat?.serverId ?? workspace.serverId, sessionId: sessionId)
    store.controllers[key]?.revealToolCall(toolCallId)
  }

  private func preview(_ target: String) {
    fileOpener?.open(ViewableFile(PreviewFile(serverPath: target)))
  }

  private func presentTranscript() {
    guard let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId) else { return }

    BotTranscriptWindows.shared.present(bot, workspace: workspace, store: store, environment: environment)
  }
}
