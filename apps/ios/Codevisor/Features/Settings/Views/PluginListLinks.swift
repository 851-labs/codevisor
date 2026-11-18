import CodevisorCore
import CodevisorUI
import SwiftUI

struct PluginListLinks: View {
  let model: PluginListsModel
  let server: ServerMcpServer

  var body: some View {
    PluginListsSection(summaries: model.summaries(for: server)) { summary in
      NavigationLink {
        destination(summary.page)
      } label: {
        PluginListRowLabel(summary)
      }
    }
  }

  @ViewBuilder
  private func destination(_ page: PluginListPage) -> some View {
    if page == .automations {
      PluginAutomationsScreen(model: model.subscriptions)
    } else {
      PluginCapabilityListPage(page, lists: model.lists(for: server), isLoading: model.isLoadingTools)
    }
  }
}
