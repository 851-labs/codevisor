import SwiftUI

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

  public struct Placement<ID: Hashable>: Equatable {
    public let id: ID
    public var visibility: SidebarRowVisibility

    public init(_ id: ID, _ visibility: SidebarRowVisibility) {
      self.id = id
      self.visibility = visibility
    }
  }

  public static func plan<ID: Hashable>(from previous: [ID], to current: [ID]) -> [Step<ID>] {
    let known = Set(previous)
    let remaining = Set(current)
    let steps = current.map { Step($0, known.contains($0) ? .kept : .arriving) }
    let leaving = previous.filter { !remaining.contains($0) }.map { Step($0, .leaving) }
    return interleave(leaving, into: steps, by: previous, id: \.id)
  }

  public static func plan<ID: Hashable>(
    from shown: [Placement<ID>], to current: [ID], fold: Int
  ) -> [Placement<ID>] {
    let visibilities = Dictionary(shown.map { ($0.id, $0.visibility) }, uniquingKeysWith: { first, _ in first })
    let present = shown.filter { $0.visibility.target == 1 }.map(\.id)
    let planned = plan(from: present, to: current).map { step in
      let visibility = visibilities[step.id] ?? .hidden
      return Placement(step.id, visibility.retargeted(to: step.fold == .leaving ? 0 : 1, by: fold))
    }
    let plannedIDs = Set(planned.map(\.id))
    let inFlight = shown.filter { !plannedIDs.contains($0.id) }
    return interleave(inFlight, into: planned, by: shown.map(\.id), id: \.id)
  }

  public static func settle<ID: Hashable>(_ shown: [Placement<ID>]) -> [Placement<ID>] {
    shown.filter { $0.visibility.target == 1 }.map { Placement($0.id, .shown) }
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

public struct SidebarRowVisibility: Hashable, Sendable {
  public struct Term: Hashable, Sendable {
    public let fold: Int
    public let change: CGFloat
  }

  public private(set) var settled: CGFloat
  public private(set) var terms: [Term]

  public static let shown = SidebarRowVisibility(settled: 1, terms: [])
  public static let hidden = SidebarRowVisibility(settled: 0, terms: [])

  public var target: CGFloat { terms.reduce(settled) { $0 + $1.change } }

  public var isFolding: Bool { !terms.isEmpty }

  public func value(at progress: SidebarFoldProgress) -> CGFloat {
    min(1, max(0, terms.reduce(settled) { $0 + $1.change * progress[$1.fold] }))
  }

  public func retargeted(to target: CGFloat, by fold: Int) -> Self {
    let change = target - self.target
    guard change != 0 else { return self }
    return Self(settled: settled, terms: terms + [Term(fold: fold, change: change)])
  }
}

public struct SidebarFoldProgress: VectorArithmetic, Sendable {
  public private(set) var folds: [CGFloat]

  public init(_ folds: [CGFloat] = []) {
    self.folds = folds
  }

  public static var zero: Self { Self() }

  public subscript(fold: Int) -> CGFloat { folds.indices.contains(fold) ? folds[fold] : 0 }

  public var count: Int { folds.count }

  public var isFolding: Bool { folds.contains { $0 > 0 && $0 < 1 } }

  public mutating func advance(_ fold: Int) {
    folds += Array(repeating: 0, count: max(0, fold + 1 - count))
    folds[fold] = 1
  }

  public static func + (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs, +) }

  public static func - (lhs: Self, rhs: Self) -> Self { combine(lhs, rhs, -) }

  public mutating func scale(by rhs: Double) {
    folds = folds.map { $0 * CGFloat(rhs) }
  }

  public var magnitudeSquared: Double { folds.reduce(0) { $0 + Double($1 * $1) } }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    (0..<max(lhs.count, rhs.count)).allSatisfy { lhs[$0] == rhs[$0] }
  }

  private static func combine(_ lhs: Self, _ rhs: Self, _ operation: (CGFloat, CGFloat) -> CGFloat) -> Self {
    Self((0..<max(lhs.count, rhs.count)).map { operation(lhs[$0], rhs[$0]) })
  }
}
