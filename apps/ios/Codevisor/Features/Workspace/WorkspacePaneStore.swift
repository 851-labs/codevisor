import CodevisorCore
import SwiftUI

@MainActor
@Observable
final class WorkspacePaneStore {
  static let shared = WorkspacePaneStore()

  private var cache: [UUID: PaneGroupState] = [:]

  private func key(for id: UUID) -> String {
    "ios.workspace.panes.\(id.uuidString)"
  }

  func state(for workspaceId: UUID, legacySessionIds: [UUID] = []) -> PaneGroupState {
    if let cached = cache[workspaceId] { return cached }
    if let data: Data = ClientPreferences.shared.valueIfPresent(
      forKey: key(for: workspaceId)
    ),
      let decoded = try? JSONDecoder().decode(PaneGroupState.self, from: data)
    {
      cache[workspaceId] = decoded
      return decoded
    }

    let legacy =
      legacySessionIds
      .filter { $0 != workspaceId }
      .compactMap { existingState(for: $0) }
      .max { $0.panes.count < $1.panes.count }
    if let decoded = legacy {
      save(decoded, for: workspaceId)
      return decoded
    }

    let initialSessionId = legacySessionIds.first ?? workspaceId
    let initial = PaneGroupState.centerInitial(sessionId: initialSessionId)
    cache[workspaceId] = initial
    return initial
  }

  func existingState(for id: UUID) -> PaneGroupState? {
    if let cached = cache[id] { return cached }
    guard let data: Data = ClientPreferences.shared.valueIfPresent(forKey: key(for: id)),
      let decoded = try? JSONDecoder().decode(PaneGroupState.self, from: data)
    else { return nil }
    cache[id] = decoded
    return decoded
  }

  func save(_ state: PaneGroupState, for workspaceId: UUID) {
    cache[workspaceId] = state
    if let data = try? JSONEncoder().encode(state) {
      ClientPreferences.shared.set(data, forKey: key(for: workspaceId))
    }
  }
}
