public struct RecentPages<ID: Hashable, Route> {
  public struct Page: Identifiable {
    public let id: ID
    public var route: Route
    fileprivate var lastShown: UInt64
  }

  public let capacity: Int
  public private(set) var pages: [Page] = []
  private var clock: UInt64 = 0

  public init(capacity: Int) {
    self.capacity = capacity
  }

  public func pages(showing route: Route?, in id: ID?) -> [Page] {
    var next = self
    if let route, let id { next.show(route, in: id) }
    return next.pages
  }

  public mutating func show(_ route: Route, in id: ID) {
    clock &+= 1
    if let index = pages.firstIndex(where: { $0.id == id }) {
      pages[index].route = route
      pages[index].lastShown = clock
    } else {
      pages.append(Page(id: id, route: route, lastShown: clock))
    }
    evictOverflow()
  }

  private mutating func evictOverflow() {
    while pages.count > capacity, let oldest = pages.min(by: { $0.lastShown < $1.lastShown }) {
      pages.removeAll { $0.id == oldest.id }
    }
  }
}
