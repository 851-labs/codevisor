public struct PluginListSummary: Identifiable, Equatable, Sendable {
  public let page: PluginListPage
  public let count: Int
  public let isLoading: Bool

  public var id: PluginListPage { page }

  public init(page: PluginListPage, count: Int, isLoading: Bool = false) {
    self.page = page
    self.count = count
    self.isLoading = isLoading
  }
}
