import SwiftUI

public struct PluginListsSection<Link: View>: View {
  private let summaries: [PluginListSummary]
  private let link: (PluginListSummary) -> Link

  public init(summaries: [PluginListSummary], @ViewBuilder link: @escaping (PluginListSummary) -> Link) {
    self.summaries = summaries
    self.link = link
  }

  public var body: some View {
    if !summaries.isEmpty {
      Section {
        ForEach(summaries) { link($0) }
      }
    }
  }
}
