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
    var trailing: [ID?: [ID]] = [:]
    var anchor: ID?
    for id in previous {
      if remaining.contains(id) {
        anchor = id
      } else {
        trailing[anchor, default: []].append(id)
      }
    }
    var steps = (trailing[nil] ?? []).map { Step($0, .leaving) }
    for id in current {
      steps.append(Step(id, known.contains(id) ? .kept : .arriving))
      steps += (trailing[id] ?? []).map { Step($0, .leaving) }
    }
    return steps
  }
}
