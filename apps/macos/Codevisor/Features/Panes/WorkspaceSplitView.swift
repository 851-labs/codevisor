//  Renders one workspace tab's split tree as a flat set of UUID-keyed leaves.
//  The tree computes geometry and divider ownership, but never owns pane
//  content: wrapping or collapsing a branch therefore cannot remount a
//  surviving terminal or chat transcript.

import SwiftUI
import AppKit
import CodevisorCore
import CodevisorUI

struct WorkspaceSplitView: View {
  let node: SplitNode
  /// The most recently active center leaf. This remains resolved while
  /// focus temporarily moves to the bottom panel or another window.
  let activeLeafId: UUID?
  let groupModel: (UUID) -> PaneGroupModel
  let paneTitle: (PaneDescriptorState) -> String
  let sessionStore: SessionStore?
  let dragCoordinator: WorkspaceSplitDragCoordinator?
  let onSplitLeaf: (UUID, SplitEdge) -> Void
  let onRenameLeaf: (UUID, String) -> Void
  let onCloseLeaf: (UUID) -> Void
  /// A local insertion whose blank shell is expanding from its requested
  /// edge. The destination content mounts only after this clears.
  var openingSplit: WorkspaceSplitOpening? = nil
  var onOpeningFinished: ((WorkspaceSplitOpening) -> Void)? = nil
  /// Called with the updated WHOLE tree after a divider drag ends.
  let onTreeChanged: (SplitNode) -> Void
  /// Called with the WHOLE tree on every frame of a divider drag (render
  /// only, nothing persisted).
  var onLiveTreeChanged: ((SplitNode) -> Void)? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.theme) private var theme
  @State private var activeDividerDrag: ActiveDividerDrag?

  var body: some View {
    GeometryReader { geometry in
      let snapshot = WorkspaceSplitLayoutSnapshot.make(
        node: node,
        size: geometry.size
      )
      let hasMultipleLeaves = snapshot.leaves.count > 1

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
          .clipped()
          .transition(openingTransition(for: opening))
        }

        ForEach(snapshot.dividers) { divider in
          if !isOpeningDivider(divider) {
            theme.separator
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
      .clipped()
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
        WorkspaceSplitDragGhost(
          name: drag.name,
          kind: drag.kind,
          isAgentOwned: drag.isAgentOwned
        )
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

/// One single-pane split leaf. The header is split chrome, not another tab
/// group: it identifies the pane and exposes leaf-targeted split actions.
private struct SplitLeafView: View {
  let leafId: UUID
  let isInactive: Bool
  /// Hidden when the leaf is alone in its tab: the split actions live in
  /// the Tabs & Splits menu, so the header would only spend a row on chrome.
  let showsHeader: Bool
  /// A new leaf stays as an inert blank shell until its size transition ends.
  let openingEdge: SplitEdge?
  let groupModel: (UUID) -> PaneGroupModel
  let paneTitle: (PaneDescriptorState) -> String
  let sessionStore: SessionStore?
  let dragCoordinator: WorkspaceSplitDragCoordinator?
  let onSplit: (SplitEdge) -> Void
  let onRename: (String) -> Void
  let onClose: () -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @Environment(\.theme) private var theme

  var body: some View {
    ZStack {
      theme.contentBackground
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
          onClose: onClose
        )
      }
      ZStack {
        Color.clear
        PaneGroupContent(group: model)
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .contentShape(Rectangle())
      .simultaneousGesture(TapGesture().onEnded { model.onActivated?() })
    }
  }

  @ViewBuilder
  private var openingDivider: some View {
    if let openingEdge {
      theme.separator
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
      .fill(theme.windowBackground)
      .opacity(isInactive ? 0.3 : 0)
      .allowsHitTesting(false)
      // Active-group changes should read as focus changes, not motion.
      .transaction { $0.animation = nil }
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
  let onClose: () -> Void

  @Environment(\.theme) private var theme
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
            .foregroundStyle(theme.textPrimary)

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
    .background(theme.contentBackground)
    .overlay(alignment: .bottom) { Divider() }
    .alert(renameAlertTitle, isPresented: $showingRename) {
      TextField("Name", text: $renameText)
      Button("Cancel", role: .cancel) {}
      Button("Rename") { onRename(renameText) }
        .disabled(renameText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }
  }

  private var iconName: String {
    switch pane?.kind {
    case .chat: "text.bubble"
    case .terminal: pane?.attachOnly == true ? "server.rack" : "terminal"
    case .plugin: "puzzlepiece.extension"
    case .document: "doc.richtext"
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
          isAgentOwned: pane.attachOnly,
          location: value.location
        )
      }
      .onEnded { _ in
        dragCoordinator?.dragEnded()
      }
  }

  /// The chat this pane is showing, once its record has loaded. Nil for
  /// terminal/new-tab panes, so chat-only menu items can opt out.
  private var chatSession: ChatSession? {
    guard pane?.kind == .chat, let sessionId = pane?.chatSessionId else { return nil }
    return environment.projectList.sessions.first(where: { $0.id == sessionId })
  }

  @ViewBuilder
  private var leadingIcon: some View {
    if let session = chatSession {
      // Matches the tint its sibling (the non-chat pane icon) uses.
      ChatSessionLeadingIcon(
        session: session,
        store: sessionStore,
        activityColor: theme.textSecondary
      )
    } else if pane?.kind == .plugin,
      let pluginId = pane?.pluginId,
      let pluginIconClient
    {
      PluginIconView(
        pluginId: pluginId,
        paneType: pane?.pluginPaneType,
        iconPath: "server",
        client: pluginIconClient,
        cacheNamespace: pluginIconCacheNamespace
      )
      .frame(width: 18, height: 11)
      .foregroundStyle(theme.textSecondary)
    } else {
      Image(systemName: iconName)
        .font(.system(size: 11, weight: .medium))
        .foregroundStyle(theme.textSecondary)
        .frame(width: 18)
    }
  }

  private var renameAlertTitle: String {
    switch pane?.kind {
    case .chat: "Rename Chat"
    case .terminal: "Rename Terminal"
    case .newTab, .plugin, .document, .none: "Rename Pane"
    }
  }

  private var closeTitle: String {
    pane?.kind == .chat && pane?.chatSessionId != nil ? "Archive" : "Close"
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
        unreadToggleButton(session)
      }

      Button(role: .destructive, action: onClose) {
        Label(closeTitle, systemImage: closeTitle == "Archive" ? "archivebox" : "xmark")
          .labelStyle(.titleAndIcon)
      }
      .shortcut(.closeSplit)
    } label: {
      Image(systemName: "ellipsis")
        .font(.system(size: 13, weight: .semibold))
        .foregroundStyle(theme.textSecondary)
        .frame(width: 24, height: 22)
        .contentShape(Rectangle())
    }
    .menuStyle(.borderlessButton)
    .menuIndicator(.hidden)
    .fixedSize()
    .help("Pane actions")
    .accessibilityLabel("Pane actions")
  }

  /// Flips between marking the pane's chat unread and clearing an existing
  /// unread badge, so the menu never offers the state the chat is already in.
  @ViewBuilder
  private func unreadToggleButton(_ session: ChatSession) -> some View {
    if isUnread(session) {
      Button {
        sessionStore?.markRead(session)
      } label: {
        Label("Mark as read", systemImage: "message")
          .labelStyle(.titleAndIcon)
      }
    } else {
      Button {
        sessionStore?.markUnread(session)
      } label: {
        Label("Mark as unread", systemImage: "message.badge")
          .labelStyle(.titleAndIcon)
      }
    }
  }

  private func isUnread(_ session: ChatSession) -> Bool {
    guard let sessionStore else { return false }
    return sessionStore.unreadCount(session) > 0 || sessionStore.hasUnreadError(session)
  }

  private func splitMenuItem(_ name: String, icon: String, edge: SplitEdge) -> some View {
    Button {
      onSplit(edge)
    } label: {
      Label(name, systemImage: icon)
        .labelStyle(.titleAndIcon)
    }
    // Leading and top have no key equivalent; `shortcut(_:)` no-ops there.
    .shortcut(.split(towards: edge))
  }
}
