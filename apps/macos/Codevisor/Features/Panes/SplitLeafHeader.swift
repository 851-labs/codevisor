import SwiftUI
import CodevisorCore
import CodevisorUI

struct SplitLeafHeader: View {
  let pane: PaneDescriptorState?
  let title: (PaneDescriptorState) -> String
  let sessionStore: SessionStore?
  let pluginIconClient: (any CodevisorServerClienting)?
  let pluginIconCacheNamespace: String
  let leafId: UUID
  let dragCoordinator: WorkspaceSplitDragCoordinator?
  let onActivate: () -> Void
  let onSplit: (SplitEdge) -> Void
  let onClose: (() -> Void)?
  let onFloat: (() -> Void)?

  @Environment(AppEnvironment.self) private var environment

  var body: some View {
    HStack(spacing: 4) {
      Button(action: onActivate) {
        HStack(spacing: 7) {
          leadingIcon

          Text(pane.map(title) ?? "New Tab")
            .font(.tabLabel(weight: .medium))
            .lineLimit(1)
            .truncationMode(.tail)
            .foregroundStyle(.primary)

          Spacer(minLength: 6)
        }
        .contentShape(Rectangle())
      }
      .buttonStyle(.plain)
      .simultaneousGesture(splitDragGesture)

      actionsMenu
    }
    .padding(.horizontal, 8)
    .frame(height: 28)
    .overlay(alignment: .bottom) { Divider() }
  }

  private var iconName: String {
    switch pane?.kind {
    case .chat: "text.bubble"
    case .terminal: "terminal"
    case .plugin: "puzzlepiece.extension"
    case .document: "doc.richtext"
    case .browser: "globe"
    case .screenSharing: "display"
    case .simulator: "iphone"
    case .subagent: "wand.and.sparkles"
    case .review: "plusminus"
    case .transcript: "text.page"
    case .childAgent: "text.bubble"
    case .newTab, .none: "square.dashed"
    }
  }

  private var splitDragGesture: some Gesture {
    DragGesture(minimumDistance: 3, coordinateSpace: .global)
      .onChanged { value in
        guard let pane, let dragCoordinator else { return }
        if dragCoordinator.active?.sourceLeafId != leafId {
          onActivate()
        }
        dragCoordinator.dragUpdated(
          sourceLeafId: leafId,
          name: title(pane),
          kind: pane.kind,
          location: value.location
        )
      }
      .onEnded { _ in
        dragCoordinator?.dragEnded()
      }
  }

  private var chatSession: ChatSession? {
    PaneMenuItems.chatSession(of: pane, in: environment.projectList)
  }

  private var isChildAgent: Bool { pane?.kind == .childAgent }

  private var subagentHarnessId: String? {
    guard pane?.kind == .subagent, let ownerId = pane?.ownerChatSessionId else { return nil }
    return environment.projectList.sessions.first(where: { $0.id == ownerId })?.harnessId
  }

  @ViewBuilder
  private var leadingIcon: some View {
    if pane?.kind == .subagent {
      HarnessIcon(harnessId: subagentHarnessId ?? "", fallbackSymbolName: iconName)
        .foregroundStyle(.secondary)
        .frame(width: 18)
    } else if let session = chatSession {
      ChatSessionLeadingIcon(session: session, store: sessionStore, isQuiet: isChildAgent)
    } else if let status = pane?.terminalAgentStatus {
      AgentStatusIndicator(status: status)
        .frame(width: 18)
    } else if pane?.kind == .plugin,
      let pluginId = pane?.pluginId,
      let pluginIconClient
    {
      PluginIconView(
        pluginId: pluginId,
        client: pluginIconClient,
        cacheNamespace: pluginIconCacheNamespace,
        side: 11
      )
      .frame(width: 18, height: 11)
      .foregroundStyle(.secondary)
    } else {
      Image(systemName: iconName)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(.secondary)
        .frame(width: 18)
    }
  }

  private var actionsMenu: some View {
    Menu {
      splitMenuItem("Split Right", icon: "rectangle.righthalf.inset.filled", edge: .trailing)
      splitMenuItem("Split Left", icon: "rectangle.lefthalf.inset.filled", edge: .leading)
      splitMenuItem("Split Down", icon: "rectangle.bottomhalf.inset.filled", edge: .bottom)
      splitMenuItem("Split Up", icon: "rectangle.tophalf.inset.filled", edge: .top)

      Divider()

      Button {
        onFloat?()
      } label: {
        Label("Float", systemImage: "macwindow.on.rectangle")
          .labelStyle(.titleAndIcon)
      }
      .disabled(onFloat == nil)

      Divider()

      PaneMenuItems(pane: pane)

      if let onClose {
        Button(role: .destructive, action: onClose) {
          Label("Close", systemImage: "xmark")
            .labelStyle(.titleAndIcon)
        }
        .shortcut(.closeSplit)
      }
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(.secondary)
        .frame(width: 24, height: 22)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Pane actions")
    .accessibilityLabel("Pane actions")
  }

  private func splitMenuItem(_ name: String, icon: String, edge: SplitEdge) -> some View {
    Button {
      onSplit(edge)
    } label: {
      Label(name, systemImage: icon)
        .labelStyle(.titleAndIcon)
    }
    .shortcut(.split(towards: edge))
  }
}
