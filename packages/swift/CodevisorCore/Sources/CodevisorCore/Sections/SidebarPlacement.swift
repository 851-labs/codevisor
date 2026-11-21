import Foundation

public struct SidebarPlacement: Equatable, Sendable {
  public var section: UUID?
  public var after: UUID?

  public init(section: UUID?, after: UUID?) {
    self.section = section
    self.after = after
  }

  public func siblings(placing id: UUID, among members: [UUID]) -> [UUID] {
    var siblings = members.filter { $0 != id }
    let predecessor = after.flatMap { after in siblings.firstIndex(of: after) }
    siblings.insert(id, at: predecessor.map { $0 + 1 } ?? 0)
    return siblings
  }
}
