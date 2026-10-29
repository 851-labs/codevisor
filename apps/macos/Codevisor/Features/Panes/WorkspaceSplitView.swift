import SwiftUI
import AppKit
import CodevisorCore
import CodevisorUI

struct WorkspaceSplitView: View {
  let node: SplitNode
  let activeLeafId: UUID?
  let groupModel: (UUID) -> PaneGroupModel
  let paneTitle: (PaneDescriptorState) -> String
  let sessionStore: SessionStore?
  let dragCoordinator: WorkspaceSplitDragCoordinator?
  let onSplitLeaf: (UUID, SplitEdge) -> Void
  let onRenameLeaf: (UUID, String) -> Void
  let onCloseLeaf: (UUID) -> Void
  var openingSplit: WorkspaceSplitOpening? = nil
  var onOpeningFinished: ((WorkspaceSplitOpening) -> Void)? = nil
  let onTreeChanged: (SplitNode) -> Void
  var onLiveTreeChanged: ((SplitNode) -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.transcriptTopChromeHeight) private var transcriptTopChromeHeight
  @State private var activeDividerDrag: ActiveDividerDrag?

  var body: some View {
    GeometryReader { geometry in
      let snapshot = WorkspaceSplitLayoutSnapshot.make(
        node: node,
        size: geometry.size
      )
      let hasMultipleLeaves = snapshot.leaves.count > 1
      let clip = WorkspaceSplitClip(extendsAboveTop: extendsChatAboveTop(snapshot))

      ZStack(alignment: .topLeading) {
        ForEach(snapshot.leaves) { leaf in
          let opening = openingSplit?.leafId == leaf.id ? openingSplit : nil
          SplitLeafView(
            leafId: leaf.id,
            isInactive: opening == nil && hasMultipleLeaves && activeLeafId != nil
              && leaf.id != activeLeafId,
            showsHeader: hasMultipleLeaves,
            openingEdge: opening?.edge,
            groupModel: groupModel,
            paneTitle: paneTitle,
            sessionStore: sessionStore,
            dragCoordinator: dragCoordinator,
            onSplit: { edge in onSplitLeaf(leaf.id, edge) },
            onRename: { name in onRenameLeaf(leaf.id, name) },
            onClose: { onCloseLeaf(leaf.id) }
          )
          .frame(
            width: max(0, leaf.frame.width),
            height: max(0, leaf.frame.height)
          )
          .position(x: leaf.frame.midX, y: leaf.frame.midY)
          .clipShape(clip)
          .transition(openingTransition(for: opening))
        }

        ForEach(snapshot.dividers) { divider in
          if !isOpeningDivider(divider) {
            Color.separatorColor
              .frame(
                width: divider.lineFrame.width,
                height: divider.lineFrame.height
              )
              .position(
                x: divider.lineFrame.midX,
                y: divider.lineFrame.midY
              )

            dividerGrip(divider)
              .frame(
                width: divider.gripFrame.width,
                height: divider.gripFrame.height
              )
              .position(
                x: divider.gripFrame.midX,
                y: divider.gripFrame.midY
              )
          }
        }
      }
      .frame(width: geometry.size.width, height: geometry.size.height)
      .clipShape(clip)
    }
    .overlay { dragGhostOverlay }
    .task(id: openingSplit?.id) {
      guard let openingSplit else { return }
      if !reduceMotion {
        try? await Task.sleep(for: .seconds(Motion.splitDuration))
      }
      guard !Task.isCancelled, self.openingSplit == openingSplit else { return }
      onOpeningFinished?(openingSplit)
    }
  }

  private func extendsChatAboveTop(_ snapshot: WorkspaceSplitLayoutSnapshot) -> Bool {
    guard transcriptTopChromeHeight > 0, snapshot.leaves.count == 1, let leaf = snapshot.leaves.first else {
      return false
    }
    return groupModel(leaf.id).state.selectedPane?.kind == .chat
  }

  private func openingTransition(for opening: WorkspaceSplitOpening?) -> AnyTransition {
    guard let opening, !reduceMotion else { return .identity }
    return .scale(scale: 0.001, anchor: opening.edge.revealAnchor)
  }

  private func isOpeningDivider(_ divider: WorkspaceSplitLayoutSnapshot.Divider) -> Bool {
    guard let openingSplit else { return false }
    switch openingSplit.edge {
    case .leading, .top:
      return divider.beforeLeafID == openingSplit.leafId
    case .trailing, .bottom:
      return divider.afterLeafID == openingSplit.leafId
    }
  }

  private func dividerGrip(
    _ divider: WorkspaceSplitLayoutSnapshot.Divider
  ) -> some View {
    SplitDividerGrip(
      isHorizontal: divider.isHorizontal,
      onChanged: { translation in
        resize(divider, translation: translation)
      },
      onEnded: finishDividerResize
    )
  }

  private func resize(
    _ divider: WorkspaceSplitLayoutSnapshot.Divider,
    translation: CGFloat
  ) {
    guard divider.contentLength > 0 else { return }
    let drag: ActiveDividerDrag
    if let activeDividerDrag, activeDividerDrag.id == divider.id {
      drag = activeDividerDrag
    } else {
      drag = ActiveDividerDrag(
        id: divider.id,
        startFractions: divider.sourceFractions,
        latestTree: node
      )
    }
    let index = divider.childIndex
    guard drag.startFractions.indices.contains(index + 1) else { return }

    let minChildLength =
      divider.isHorizontal
      ? WorkspaceSplitDragCoordinator.minChildWidth
      : WorkspaceSplitDragCoordinator.minChildHeight
    let minFraction = Double(minChildLength / divider.contentLength)
    var delta = Double(translation / divider.contentLength)
    delta = max(delta, minFraction - drag.startFractions[index])
    delta = min(delta, drag.startFractions[index + 1] - minFraction)
    var updatedFractions = drag.startFractions
    updatedFractions[index] = drag.startFractions[index] + delta
    updatedFractions[index + 1] = drag.startFractions[index + 1] - delta
    let updatedTree = node.replacingSplitFractions(
      at: divider.branchPath,
      with: updatedFractions
    )
    activeDividerDrag = ActiveDividerDrag(
      id: divider.id,
      startFractions: drag.startFractions,
      latestTree: updatedTree
    )
    onLiveTreeChanged?(updatedTree)
  }

  private func finishDividerResize() {
    guard let activeDividerDrag else { return }
    self.activeDividerDrag = nil
    onTreeChanged(activeDividerDrag.latestTree)
  }

  private var dragGhostOverlay: some View {
    GeometryReader { proxy in
      if let drag = dragCoordinator?.active {
        WorkspaceSplitDragGhost(name: drag.name, kind: drag.kind)
          .position(
            x: drag.location.x - proxy.frame(in: .global).minX,
            y: drag.location.y - proxy.frame(in: .global).minY
          )
      }
    }
    .allowsHitTesting(false)
  }
}

private struct ActiveDividerDrag {
  let id: WorkspaceSplitLayoutSnapshot.DividerID
  let startFractions: [Double]
  let latestTree: SplitNode
}

private extension SplitEdge {
  var revealAnchor: UnitPoint {
    switch self {
    case .leading: .leading
    case .trailing: .trailing
    case .top: .top
    case .bottom: .bottom
    }
  }
}

private struct SplitLeafView: View {
  let leafId: UUID
  let isInactive: Bool
  let showsHeader: Bool
  let openingEdge: SplitEdge?
  let groupModel: (UUID) -> PaneGroupModel
  let paneTitle: (PaneDescriptorState) -> String
  let sessionStore: SessionStore?
  let dragCoordinator: WorkspaceSplitDragCoordinator?
  let onSplit: (SplitEdge) -> Void
  let onRename: (String) -> Void
  let onClose: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion

  var body: some View {
    ZStack {
      Color.clear
      if openingEdge == nil {
        leafContent
          .transition(.opacity)
      }
    }
    .frame(maxWidth: .infinity, maxHeight: .infinity)
    .overlay { inactiveSplitTint }
    .overlay { openingDivider }
    .workspaceSplitDropZone(dragCoordinator, leafId: leafId)
    .allowsHitTesting(openingEdge == nil)
    .animation(Motion.quick(reduceMotion: reduceMotion), value: openingEdge == nil)
  }

  private func holdsMainChat(_ model: PaneGroupModel) -> Bool {
    guard let pane = model.state.selectedPane else { return false }
    return model.isWorkspaceMainChat?(pane) == true
  }

  private var leafContent: some View {
    let model = groupModel(leafId)
    return VStack(spacing: 0) {
      if showsHeader {
        SplitLeafHeader(
          pane: model.state.selectedPane,
          title: paneTitle,
          sessionStore: sessionStore,
          pluginIconClient: model.pluginIconClient,
          pluginIconCacheNamespace: model.pluginIconCacheNamespace,
          leafId: leafId,
          dragCoordinator: dragCoordinator,
          onActivate: { model.onActivated?() },
          onSplit: onSplit,
          onRename: onRename,
          onClose: holdsMainChat(model) ? nil : onClose
        )
      }
      ZStack {
        Color.clear
        PaneGroupContent(group: model)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .background { PaneActivationObserver { model.onActivated?() } }
    }
  }

  @ViewBuilder
  private var openingDivider: some View {
    if let openingEdge {
      Color.separatorColor
        .frame(
          maxWidth: openingEdge == .top || openingEdge == .bottom
            ? .infinity : nil,
          maxHeight: openingEdge == .leading || openingEdge == .trailing
            ? .infinity : nil
        )
        .frame(
          width: openingEdge == .leading || openingEdge == .trailing ? 1 : nil,
          height: openingEdge == .top || openingEdge == .bottom ? 1 : nil
        )
        .frame(
          maxWidth: .infinity,
          maxHeight: .infinity,
          alignment: openingEdge.dividerAlignment
        )
        .allowsHitTesting(false)
    }
  }

  private var inactiveSplitTint: some View {
    Rectangle()
      .fill(Color.windowBackgroundColor)
      .opacity(isInactive ? 0.3 : 0)
      .allowsHitTesting(false)
      .transaction { $0.animation = nil }
  }
}

private struct SplitLeafHeader: View {
  let pane: PaneDescriptorState?
  let title: (PaneDescriptorState) -> String
  let sessionStore: SessionStore?
  let pluginIconClient: (any CodevisorServerClienting)?
  let pluginIconCacheNamespace: String
  let leafId: UUID
  let dragCoordinator: WorkspaceSplitDragCoordinator?
  let onActivate: () -> Void
  let onSplit: (SplitEdge) -> Void
  let onRename: (String) -> Void
  let onClose: (() -> Void)?

  @Environment(AppEnvironment.self) private var environment
  @State private var renameText = ""
  @State private var showingRename = false

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
    .alert(renameAlertTitle, isPresented: $showingRename) {
      TextField("Name", text: $renameText)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { onRename(renameText) }
        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
    .focusesAlertTextField(when: showingRename)
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
    guard pane?.kind == .chat, let sessionId = pane?.chatSessionId else { return nil }
    return environment.projectList.sessions.first(where: { $0.id == sessionId })
  }

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
      ChatSessionLeadingIcon(session: session, store: sessionStore)
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

  private var renameAlertTitle: String {
    switch pane?.kind {
    case .chat: "Rename Chat"
    case .terminal: "Rename Terminal"
    case .newTab, .plugin, .document, .browser, .screenSharing, .subagent, .review, .simulator, .transcript, .none:
      "Rename Pane"
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
        renameText = pane.map(title) ?? "New Tab"
        showingRename = true
      } label: {
        Label("Rename", systemImage: "pencil")
          .labelStyle(.titleAndIcon)
      }

      if let session = chatSession {
        ChatSessionUnreadMenuItem(session: session, store: sessionStore)
      }

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

private extension SplitEdge {
  var dividerAlignment: Alignment {
    switch self {
    case .leading: .trailing
    case .trailing: .leading
    case .top: .bottom
    case .bottom: .top
    }
  }
}
