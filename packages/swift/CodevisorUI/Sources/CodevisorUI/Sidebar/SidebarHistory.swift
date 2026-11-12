public struct SidebarHistory<Item: Identifiable & Hashable>: Hashable {
  public static var defaultLimit: Int { 100 }

  private var items: [Item] = []
  private var position: Int?
  private var isAway = false
  private let limit: Int

  public init(limit: Int = defaultLimit) {
    self.limit = limit
  }

  public mutating func visit(_ item: Item) {
    isAway = false
    if let position, items[position].id == item.id {
      items[position] = item
      return
    }

    dropForward()
    items.append(item)
    trimToLimit()
    position = items.count - 1
  }

  public mutating func leave() {
    dropForward()
    isAway = true
  }

  public func canGoBack(where isAvailable: (Item) -> Bool) -> Bool {
    backIndex(where: isAvailable) != nil
  }

  public func canGoForward(where isAvailable: (Item) -> Bool) -> Bool {
    forwardIndex(where: isAvailable) != nil
  }

  public mutating func goBack(where isAvailable: (Item) -> Bool) -> Item? {
    move(to: backIndex(where: isAvailable))
  }

  public mutating func goForward(where isAvailable: (Item) -> Bool) -> Item? {
    move(to: forwardIndex(where: isAvailable))
  }

  private func backIndex(where isAvailable: (Item) -> Bool) -> Int? {
    guard let position else { return nil }

    let newest = isAway ? position : position - 1
    return items.indices.prefix(newest + 1).last { isAvailable(items[$0]) }
  }

  private func forwardIndex(where isAvailable: (Item) -> Bool) -> Int? {
    guard let position, !isAway else { return nil }

    return items.indices.dropFirst(position + 1).first { isAvailable(items[$0]) }
  }

  private mutating func move(to index: Int?) -> Item? {
    guard let index else { return nil }

    position = index
    isAway = false
    return items[index]
  }

  private mutating func dropForward() {
    guard let position else { return }

    items.removeSubrange((position + 1)...)
  }

  private mutating func trimToLimit() {
    let overflow = items.count - limit
    guard overflow > 0 else { return }

    items.removeFirst(overflow)
  }
}
