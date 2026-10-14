import CodevisorCore
import CodevisorUI
import SwiftUI

struct SubagentRoute: Hashable, Identifiable {
  let parentSessionId: UUID
  let toolCallId: String
  let title: String
  let mirror: SubagentMirror
  let surfaceID = UUID()

  var id: String { "\(parentSessionId.uuidString):\(toolCallId)" }

  static func == (lhs: Self, rhs: Self) -> Bool { lhs.id == rhs.id && lhs.mirror === rhs.mirror }
  func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

extension WorkspaceScreen {
  var openSubagentAction: OpenSubagentAction {
    OpenSubagentAction { parentId, toolCallId, title, _ in
      guard let parent = chatController(forChat: parentId) else { return }
      presentedSubagent = SubagentRoute(
        parentSessionId: parentId, toolCallId: toolCallId, title: title,
        mirror: SubagentMirror(parent: parent, toolCallId: toolCallId))
    }
  }
}

struct SubagentScreen: View {
  let route: SubagentRoute
  @Environment(\.windowID) private var windowID

  private var mirror: SubagentMirror { route.mirror }

  var body: some View {
    content
      .navigationTitle(mirror.summary?.title ?? route.title)
      .navigationBarTitleDisplayMode(.inline)
      .task { mirror.start() }
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
