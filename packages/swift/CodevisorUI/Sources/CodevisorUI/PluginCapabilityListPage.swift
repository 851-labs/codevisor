import SwiftUI

public struct PluginCapabilityListPage: View {
  private let page: PluginListPage
  private let lists: PluginCapabilityLists
  private let isLoading: Bool

  public init(_ page: PluginListPage, lists: PluginCapabilityLists, isLoading: Bool = false) {
    self.page = page
    self.lists = lists
    self.isLoading = isLoading
  }

  public var body: some View {
    Form {
      Section { rows }
    }
    .formStyle(.grouped)
    .navigationTitle(page.title)
    #if os(iOS)
      .navigationBarTitleDisplayMode(.inline)
    #endif
  }

  @ViewBuilder
  private var rows: some View {
    let items = lists.items(for: page)
    if items.isEmpty && isLoading {
      ProgressView().frame(maxWidth: .infinity)
    } else if items.isEmpty {
      Text("No \(page.title.lowercased()) available").foregroundStyle(.secondary)
    } else {
      ForEach(items) { PluginCapabilityRow(name: $0.name, detail: $0.detail, isApp: $0.isApp) }
    }
  }
}
