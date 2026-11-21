import CoreGraphics
import Foundation
import Observation

@MainActor
@Observable
public final class SidebarReorder<RowID: Hashable> {
  public enum Lift: Equatable {
    case item(UUID, SidebarDropRegion<RowID>)
    case block(SidebarDropBlocks<RowID>)
  }

  public enum Target: Equatable {
    case item(SidebarItemDropTarget)
    case block(Int)
  }

  public struct Lifted: Equatable {
    public let row: RowID
    public let lift: Lift
    let frame: CGRect
  }

  public struct Drop: Equatable {
    public let lifted: Lifted
    public let target: Target
  }

  private static var settleDuration: Duration { .milliseconds(250) }

  public private(set) var lifted: Lifted?
  public private(set) var target: Target?
  public private(set) var translation: CGFloat = 0
  public private(set) var isSettling = false
  @ObservationIgnored public var frames: [RowID: CGRect] = [:]

  public init() {}

  public var allowsToggle: Bool { lifted == nil && !isSettling }

  public var ghostFrame: CGRect? {
    lifted?.frame.offsetBy(dx: 0, dy: translation)
  }

  public var insertionLine: CGRect? {
    guard let lifted, let target else { return nil }

    switch (lifted.lift, target) {
    case let (.item(id, region), .item(.insertion(index))):
      return region.insertionLine(at: index, dragging: id, frames: frames)
    case let (.block(blocks), .block(index)):
      return blocks.insertionLine(at: index, dragging: lifted.row, frames: frames)
    default:
      return nil
    }
  }

  public func isLifted(_ row: RowID) -> Bool {
    lifted?.row == row
  }

  public func isHeaderTarget(_ section: UUID?) -> Bool {
    target == .item(.header(section: section))
  }

  public func liftItem(_ id: UUID, row: RowID, in region: SidebarDropRegion<RowID>) {
    lift(row, .item(id, region.measured(in: frames)))
  }

  public func liftBlock(_ row: RowID, in blocks: SidebarDropBlocks<RowID>) {
    lift(row, .block(blocks.measured(in: frames)))
  }

  public func drag(by translation: CGFloat) {
    guard let lifted else { return }

    self.translation = translation
    let next = target(for: lifted, ghost: lifted.frame.offsetBy(dx: 0, dy: translation))
    if next != target { target = next }
  }

  public func drop() -> Drop? {
    guard let lifted else { return nil }

    let drop = target.map { Drop(lifted: lifted, target: $0) }
    self.lifted = nil
    target = nil
    translation = 0
    settle()
    return drop
  }

  private func lift(_ row: RowID, _ lift: Lift) {
    guard lifted == nil, let frame = frames[row], frame != .zero else { return }

    lifted = Lifted(row: row, lift: lift, frame: frame)
    target = nil
    translation = 0
  }

  private func target(for lifted: Lifted, ghost: CGRect) -> Target? {
    switch lifted.lift {
    case let .item(id, region):
      region.target(dragging: id, ghost: ghost, frames: frames).map(Target.item)
    case let .block(blocks):
      blocks.target(dragging: lifted.row, midY: ghost.midY, frames: frames).map(Target.block)
    }
  }

  private func settle() {
    isSettling = true
    Task { [weak self] in
      try? await Task.sleep(for: Self.settleDuration)
      self?.isSettling = false
    }
  }
}
