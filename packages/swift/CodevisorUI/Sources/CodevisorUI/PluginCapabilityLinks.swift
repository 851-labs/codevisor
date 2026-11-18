import SwiftUI

public struct PluginCapabilityLinks: View {
  private let lists: PluginCapabilityLists

  public init(lists: PluginCapabilityLists) {
    self.lists = lists
  }

  public var body: some View {
    PluginListsSection(summaries: lists.summaries) { summary in
      NavigationLink {
        PluginCapabilityListPage(summary.page, lists: lists)
          .modifier(ClearsInitialFocus())
      } label: {
        PluginListRowLabel(summary)
      }
    }
  }
}
