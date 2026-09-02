import CodevisorCore
import SwiftUI

/// Client-side persistence of each workspace's panes, reusing the shared
/// `PaneGroupState`/`PaneDescriptorState` model — including the
/// `"<sessionUuid>:<paneUuid>"` terminal-key scheme, so pane PTYs are keyed
/// identically to macOS. Returning to a workspace restores the same panes
/// with the same pane selected.
@MainActor
@Observable
final class WorkspacePaneStore {
  static let shared = WorkspacePaneStore()

  private var cache: [UUID: PaneGroupState] = [:]

  private func key(for id: UUID) -> String {
    "ios.workspace.panes.\(id.uuidString)"
  }

  /// Pane state belongs to the workspace, not whichever chat happened to
  /// route into it. `legacySessionIds` migrates layouts written before iOS
  /// learned about multi-chat workspaces, when the storage key was the
  /// routed session id.
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

    // A later chat-row tap in an old build may have created a second,
    // one-chat legacy state. Prefer the richest candidate so the original
    // workspace (with its terminals and sibling chats) wins migration.
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

  /// Existing state only—used to discover relationships written by older
  /// iOS versions without manufacturing new pane groups during a backfill.
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

  /// A chat-row tap is an explicit request for that chat, so select its pane
  /// before Home pushes the workspace. If the shared workspace knows about a
  /// chat that this device has never rendered, add its iOS tab on demand.
  func selectChat(
    _ sessionId: UUID,
    in workspaceId: UUID,
    legacySessionIds: [UUID]
  ) {
    var state = state(for: workspaceId, legacySessionIds: legacySessionIds)
    if let pane = state.panes.first(where: {
      $0.kind == .chat && $0.chatSessionId == sessionId
    }) {
      state.selectPane(id: pane.id)
    } else {
      _ = state.addChatPane(sessionId: sessionId)
    }
    save(state, for: workspaceId)
  }
}
