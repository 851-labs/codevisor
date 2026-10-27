import AppKit
import CodevisorCore
import CodevisorUI

struct BotPageInspectorOpener {
  let workspace: Workspace
  let rootDirectory: String
  let environment: AppEnvironment
  let store: SessionStore
  let quickLook: QuickLookController?

  func open(_ destination: WorkspaceInspectorView.Destination) {
    switch destination {
    case let .pullRequest(url), let .link(url):
      NSWorkspace.shared.open(url)
    case let .file(path), let .previewFile(path):
      preview(path)
    case .botTranscript:
      presentTranscript()
    }
  }

  private var isLocalMachine: Bool {
    environment.machines.machine(for: workspace.serverId)?.isLocal == true
  }

  private func preview(_ target: String) {
    guard isLocalMachine, let path = FileDocumentLocation.resolve(target, relativeTo: rootDirectory) else { return }

    quickLook?.updatePreviewURL(URL(fileURLWithPath: path))
  }

  private func presentTranscript() {
    guard let bot = environment.bots.bot(forWorkspace: workspace.id, serverId: workspace.serverId) else { return }

    BotTranscriptWindows.shared.present(bot, workspace: workspace, store: store, environment: environment)
  }
}
