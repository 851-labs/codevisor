public enum SidebarRowFold: Equatable, Sendable {
  case kept
  case arriving
  case leaving

  public struct Step<ID: Hashable>: Equatable {
    public let id: ID
    public let fold: SidebarRowFold

    public init(_ id: ID, _ fold: SidebarRowFold) {
      self.id = id
      self.fold = fold
    }
  }

  public static func plan<ID: Hashable>(from previous: [ID], to current: [ID]) -> [Step<ID>] {
    let known = Set(previous)
    let remaining = Set(current)
    let steps = current.map { Step($0, known.contains($0) ? .kept : .arriving) }
    let leaving = previous.filter { !remaining.contains($0) }.map { Step($0, .leaving) }
    return interleave(leaving, into: steps, by: previous, id: \.id)
  }

  public static func interleave<Element, ID: Hashable>(
    _ leaving: [Element], into elements: [Element], by previous: [ID], id: (Element) -> ID
  ) -> [Element] {
    let present = Set(elements.map(id))
    let leavingByID = Dictionary(leaving.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    var trailing: [ID?: [Element]] = [:]
    var anchor: ID?
    var placed: Set<ID> = []
    for previousID in previous {
      if present.contains(previousID) {
        anchor = previousID
      } else if let element = leavingByID[previousID] {
        trailing[anchor, default: []].append(element)
        placed.insert(previousID)
      }
    }
    var merged = trailing[nil] ?? []
    for element in elements {
      merged.append(element)
      merged += trailing[id(element)] ?? []
    }
    return merged + leaving.filter { !placed.contains(id($0)) }
  }
}
