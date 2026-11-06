import CoreGraphics
import Foundation

public struct FloatingPaneKey: Codable, Hashable, Sendable {
  public let workspaceId: UUID
  public let leafId: UUID

  public init(workspaceId: UUID, leafId: UUID) {
    self.workspaceId = workspaceId
    self.leafId = leafId
  }
}

public struct FloatingPane: Codable, Equatable, Sendable {
  public let workspaceId: UUID
  public let leafId: UUID
  public var frame: CGRect?

  public var key: FloatingPaneKey {
    FloatingPaneKey(workspaceId: workspaceId, leafId: leafId)
  }

  func moved(to frame: CGRect) -> FloatingPane {
    var moved = self
    moved.frame = frame
    return moved
  }
}

@MainActor
public struct FloatingPanes {
  public static let shared = FloatingPanes(preferences: .shared)
  static let preferenceKey = "floatingPanes"

  private let preferences: ClientPreferences

  public init(preferences: ClientPreferences) {
    self.preferences = preferences
  }

  public func panes(in workspaceId: UUID) -> [FloatingPane] {
    all.filter { $0.workspaceId == workspaceId }
  }

  public func leafIds(in workspaceId: UUID) -> Set<UUID> {
    Set(panes(in: workspaceId).map(\.leafId))
  }

  public func float(_ key: FloatingPaneKey) {
    guard !all.contains(where: { $0.key == key }) else { return }

    save(all + [FloatingPane(workspaceId: key.workspaceId, leafId: key.leafId)])
  }

  public func dock(_ key: FloatingPaneKey) {
    dock([key])
  }

  public func dock(_ docked: Set<FloatingPaneKey>) {
    let remaining = all.filter { !docked.contains($0.key) }
    guard remaining.count != all.count else { return }

    save(remaining)
  }

  public func move(_ key: FloatingPaneKey, to frame: CGRect) {
    save(all.map { $0.key == key ? $0.moved(to: frame) : $0 })
  }

  public func bringToFront(_ key: FloatingPaneKey) {
    guard let pane = all.first(where: { $0.key == key }), all.last != pane else { return }

    save(all.filter { $0.key != key } + [pane])
  }

  private var all: [FloatingPane] {
    preferences.value(forKey: Self.preferenceKey, default: [FloatingPane]())
  }

  private func save(_ panes: [FloatingPane]) {
    preferences.set(panes, forKey: Self.preferenceKey)
  }
}
