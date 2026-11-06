import Foundation

public struct FloatingPaneKey: Codable, Hashable, Sendable {
  public let workspaceId: UUID
  public let leafId: UUID

  public init(workspaceId: UUID, leafId: UUID) {
    self.workspaceId = workspaceId
    self.leafId = leafId
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

  public var workspaceIds: Set<UUID> {
    Set(keys.map(\.workspaceId))
  }

  public func leafIds(in workspaceId: UUID) -> Set<UUID> {
    Set(keys.filter { $0.workspaceId == workspaceId }.map(\.leafId))
  }

  public func float(_ key: FloatingPaneKey) {
    save(keys.union([key]))
  }

  public func dock(_ key: FloatingPaneKey) {
    dock([key])
  }

  public func dock(_ docked: Set<FloatingPaneKey>) {
    let remaining = keys.subtracting(docked)
    guard remaining != keys else { return }

    save(remaining)
  }

  private var keys: Set<FloatingPaneKey> {
    Set(preferences.value(forKey: Self.preferenceKey, default: [FloatingPaneKey]()))
  }

  private func save(_ keys: Set<FloatingPaneKey>) {
    let ordered = keys.sorted {
      ($0.workspaceId.uuidString, $0.leafId.uuidString) < ($1.workspaceId.uuidString, $1.leafId.uuidString)
    }
    preferences.set(ordered, forKey: Self.preferenceKey)
  }
}
