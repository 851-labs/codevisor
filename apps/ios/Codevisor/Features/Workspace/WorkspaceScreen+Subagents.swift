import CodevisorCore
import CodevisorUI
import SwiftUI

/// A subagent opened from a chat. iOS shows one pane at a time, so a subagent
/// pushes onto the stack the workspace is in — the phone's stack, or the
/// detail column's on iPad and an unfolded iPhone Duo — with the standard
/// back button and edge swipe on every size class.
struct SubagentRoute: Hashable, Identifiable {
  let parentSessionId: UUID
  let toolCallId: String
  let title: String
  /// Created once, when the agent is opened; popping the route releases it.
  let mirror: SubagentMirror
  /// The transcript surface's identity for this push.
  let surfaceID = UUID()

  var id: String { "\(parentSessionId.uuidString):\(toolCallId)" }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.mirror === rhs.mirror }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension WorkspaceScreen {
  /// Every placement pushes: iOS has no side-by-side panes.
  var openSubagentAction: OpenSubagentAction {
    OpenSubagentAction { parentId, toolCallId, title, _ in
      guard let parent = chatController(forChat: parentId) else { return }
      presentedSubagent = SubagentRoute(
        parentSessionId: parentId, toolCallId: toolCallId, title: title,
        mirror: SubagentMirror(parent: parent, toolCallId: toolCallId))
    }
  }
}

/// A subagent's thread: the ordinary chat surface, read-only.
struct SubagentScreen: View {
  let route: SubagentRoute
  @Environment(\.windowID) private var windowID

  private var mirror: SubagentMirror { route.mirror }

  var body: some View {
    content
      .navigationTitle(mirror.summary?.title ?? route.title)
      .navigationBarTitleDisplayMode(.inline)
      .task { mirror.start() }
      // The parent streams at its visible cadence while its agent is on
      // screen, though this push hides the parent's own transcript.
      .onAppear { mirror.viewDidAppear() }
      .onDisappear { mirror.viewDidDisappear() }
  }

  @ViewBuilder
  private var content: some View {
    switch mirror.availability {
    case .available:
      SessionTranscriptView(
        controller: mirror.controller,
        presentationSurface: TranscriptPresentationSurfaceCache.shared.surface(
          for: .init(paneID: route.surfaceID, isNewChat: false, windowID: windowID),
          controller: mirror.controller
        ),
        isReadOnly: true
      )
    case .loading:
      ProgressView()
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    case .unavailable:
      SubagentUnavailableView()
    }
  }
}

private struct SubagentUnavailableView: View {
  var body: some View {
    ContentUnavailableView(
      "Agent Unavailable",
      systemImage: "wand.and.sparkles",
      description: Text("This agent is no longer in its chat's history.")
    )
  }
}
