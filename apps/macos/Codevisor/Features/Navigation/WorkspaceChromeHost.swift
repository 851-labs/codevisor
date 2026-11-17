import CodevisorCore
import CodevisorUI
import SimulatorPane
import SwiftUI

struct WorkspaceChromeHost: View {
  let navigation: WindowNavigation
  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    if let chrome = navigation.activePage?.chrome {
      WorkspaceSceneChrome(
        title: title(of: chrome), removesTitle: chrome.removesTitle,
        values: WorkspaceSceneValues(
          browser: chrome.toolbar?.browser, file: chrome.toolbar?.file, simulator: chrome.toolbar?.simulator,
          layoutActions: .routed(from: navigation.id) { navigation.activePage?.chrome?.layoutActions })
      ) {
        WorkspacePaneToolbar(source: chrome.toolbar, title: chrome.title)
      }
    }
  }

  private func title(of chrome: WorkspaceChrome) -> WorkspaceSceneTitle {
    guard let renamed = chrome.renamedChat else { return .fixed(chrome.title) }

    return .editable(
      Binding(
        get: { chrome.title },
        set: { title in
          guard let chat = environment.projectList.chat(renamed.id, preferring: renamed.serverId) else { return }

          environment.projectList.renameSession(chat, to: title)
        }
      ))
  }
}
