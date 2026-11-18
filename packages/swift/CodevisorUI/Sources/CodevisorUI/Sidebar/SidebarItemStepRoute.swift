@MainActor
public struct SidebarItemStepRoute {
  public typealias Step = @MainActor (Int) -> Void

  private let page: (@MainActor () -> Step?)?
  private let sidebar: Step?

  public init(page: (@MainActor () -> Step?)?, sidebar: Step?) {
    self.page = page
    self.sidebar = sidebar
  }

  public var isAvailable: Bool { page != nil || sidebar != nil }

  public func step(_ offset: Int) {
    if let shownPage = page?() {
      shownPage(offset)
    } else {
      sidebar?(offset)
    }
  }
}
