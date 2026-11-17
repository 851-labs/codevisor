import CodevisorCore
import CodevisorUI
import SimulatorPane
import SwiftUI

struct WorkspaceChromeHost: View {
  let navigation: WindowNavigation
  @Environment(AppEnvironment.self) private var environment
  @State private var shown: WorkspaceChrome?

  var body: some View {
    let published = navigation.activePage?.chrome
    Group {
      if navigation.deck.activeSlot != nil, let chrome = published ?? shown {
        WorkspaceSceneChrome(
          title: title(of: chrome), removesTitle: chrome.removesTitle,
          values: WorkspaceSceneValues(
            browser: chrome.toolbar?.browser, file: chrome.toolbar?.file, simulator: chrome.toolbar?.simulator,
            layoutActions: .routed { navigation.activePage?.chrome?.layoutActions })
        ) {
          WorkspacePaneToolbar(source: chrome.toolbar, title: chrome.title)
        }
      }
    }
    .onChange(of: published, initial: true) { _, published in
      if let published { shown = published }
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
