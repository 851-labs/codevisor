import SwiftUI
import CodevisorCore
import ACPKit

/// The active session screen: hosts the center pane group (the chat pane —
/// see ChatScreen — plus any terminals beside it) over the ⌘J bottom panel,
/// and owns the wiring both share: focus routing and the attachment
/// store/drop target.
struct SessionScreen: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Bindable var controller: SessionController
    /// The ⌘J bottom panel's pane group.
    var paneGroup: PaneGroupModel
    /// The center pane group: the chat pane plus any terminals opened (or
    /// dropped) beside it. Always visible — it IS the page content. Its tab
    /// strip is hosted by the container in the window's top bar.
    var centerGroup: PaneGroupModel
    /// The session's focus coordinator. Owned by the container (which also
    /// wires every center leaf's chat content with it); previews get their
    /// own.
    var focus: TerminalFocusController = TerminalFocusController()
    /// The workspace's center split tree + leaf plumbing (nil-safe defaults
    /// keep previews on the single-group path).
    var centerTree: SplitNode? = nil
    var primaryLeafId: UUID? = nil
    /// The active split leaf (keyboard target).
    var activeLeafId: UUID? = nil
    var centerLeafModel: ((UUID) -> PaneGroupModel)? = nil
    var centerPaneTitle: ((PaneDescriptorState) -> String)? = nil
    var sessionStore: SessionStore? = nil
    var splitDragCoordinator: WorkspaceSplitDragCoordinator? = nil
    var onSplitLeaf: ((UUID, SplitEdge) -> Void)? = nil
    var onRenameLeaf: ((UUID, String) -> Void)? = nil
    var onCloseLeaf: ((UUID) -> Void)? = nil
    /// Diverged-directory badge for bottom-panel tabs.
    var paneWorktreeLookup: ((PaneDescriptorState) -> String?)? = nil
    var onCenterTreeChanged: ((SplitNode) -> Void)? = nil
    /// Streamed on every frame of a divider drag (render only) so the
    /// container's top-bar segments track the moving content divider.
    var onCenterTreeLiveChanged: ((SplitNode) -> Void)? = nil
    @State private var attachmentImages: AttachmentImageStore?

    var body: some View {
        VStack(spacing: 0) {
            centerContent

            // The bottom panel (tab bar + selected pane) mounts only while
            // open. ⌘J and View ▸ Toggle Bottom Panel bring it back; the
            // bar's top edge is the resize handle.
            if paneGroup.state.isVisible {
                VStack(spacing: 0) {
                    PaneGroupBar(
                        group: paneGroup,
                        dragCoordinator: nil,
                        paneWorktree: paneWorktreeLookup,
                        // The bottom bar is the shortcuts' target while one
                        // of its terminals holds keyboard focus.
                        showsShortcutHints: paneGroup.hasFocusedPane,
                        onToggle: { togglePanes() }
                    )
                    PaneGroupContent(group: paneGroup)
                        .frame(height: paneGroup.state.height)
                }
                .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        // Anchors the focus controller's key-command guard (⌘T/⌘W/⌘1-9) to
        // this window — the composer's window can't serve: it unmounts with
        // the chat tab whenever a terminal or New tab page is selected.
        .background(
            HostWindowCapture { [weak focus] window in
                focus?.hostWindow = window
            }
            .frame(width: 0, height: 0)
        )
        .animation(Motion.panel(reduceMotion: reduceMotion), value: paneGroup.state.isVisible)
        .focusedSceneValue(\.terminalToggle, TerminalToggleAction(sessionId: paneGroup.sessionId) {
            togglePanes()
        })
        // (Background-task terminal tabs are synced by the WORKSPACE
        // container across every chat's controller — a per-chat sync here
        // would prune sibling chats' tabs on chat switches.)
        .onChange(of: controller.todos, initial: true) { _, todos in
            guard controller.observeTodoCompletion(todos), controller.isTodosExpanded else {
                return
            }
            withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
                controller.isTodosExpanded = false
            }
        }
        .onAppear {
            focus.paneGroup = paneGroup
            // Tab commands pressed while the chat has focus act on the
            // center group.
            focus.centerGroup = centerGroup
            // ⌘J from inside a focused terminal routes here (the menu command
            // doesn't fire reliably while an AppKit view is first responder).
            // The relay serves EVERY center leaf's model (the container
            // wires each one to it); the bottom panel wires directly.
            focus.requestPanelToggle = { togglePanes() }
            paneGroup.requestToggle = { togglePanes() }
            // ⌘W closing the last bottom tab collapses the panel; focus
            // returns to the composer. (Center leaves get their KEYED
            // composer-focus wiring from the container — don't overwrite
            // it here.)
            paneGroup.requestComposerFocus = { focus.focusComposer() }
            // Drop handling (bar inserts, content joins, splits) is wired by
            // the container, which owns the workspace tree.
            focus.startTypeToFocus()
            if attachmentImages == nil {
                attachmentImages = AttachmentImageStore { [weak controller] fileId in
                    guard let controller else { throw SessionControllerError.serverUnavailable }
                    return try await controller.fileData(id: fileId)
                }
            }
        }
        .onDisappear {
            focus.stopTypeToFocus()
            splitDragCoordinator?.dragCancelled()
        }
        .environment(\.attachmentImages, attachmentImages)
        .attachmentDropTarget(controller)
    }

    /// The center area: one top-level workspace tab's content-only split
    /// tree. A single-pane tab is just the tree's lone leaf.
    private var centerContent: some View {
        Group {
            if let centerTree, let centerLeafModel {
                WorkspaceSplitView(
                    node: centerTree,
                    activeLeafId: activeLeafId ?? primaryLeafId,
                    groupModel: centerLeafModel,
                    paneTitle: centerPaneTitle ?? { $0.name },
                    sessionStore: sessionStore,
                    dragCoordinator: splitDragCoordinator,
                    onSplitLeaf: { leafId, edge in onSplitLeaf?(leafId, edge) },
                    onRenameLeaf: { leafId, name in onRenameLeaf?(leafId, name) },
                    onCloseLeaf: { leafId in onCloseLeaf?(leafId) },
                    onTreeChanged: { onCenterTreeChanged?($0) },
                    onLiveTreeChanged: { onCenterTreeLiveChanged?($0) }
                )
            } else {
                // Previews (no workspace tree wired).
                PaneGroupContent(group: centerGroup)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// Toggles the pane group's content and moves keyboard focus to match
    /// (selected pane on open, composer on close).
    private func togglePanes() {
        let target = paneGroup.toggle()
        // Defer focus until SwiftUI has mounted/removed the panel.
        DispatchQueue.main.async { focus.apply(target) }
    }
}

#if DEBUG
#Preview("Conversation") {
    SessionScreen(
        controller: .preview(model: .preview()),
        paneGroup: previewPaneGroup(placement: .bottom),
        centerGroup: previewPaneGroup(placement: .center),
    )
    .frame(width: 900, height: 680)
}

#Preview("With terminal") {
    let group = previewPaneGroup(placement: .bottom)
    group.toggle()
    return SessionScreen(
        controller: .preview(model: .preview()),
        paneGroup: group,
        centerGroup: previewPaneGroup(placement: .center),
    )
    .frame(width: 900, height: 680)
}

private func previewPaneGroup(placement: PaneGroupPlacement) -> PaneGroupModel {
    let project = Project.fromFolder(URL(fileURLWithPath: "/tmp/shepherd"))
    let session = ChatSession(projectId: project.id, title: "Preview")
    return PaneGroupModel(
        sessionId: session.id,
        placement: placement,
        repository: DefaultPaneGroupRepository(store: InMemoryStore()),
        makeContext: { descriptor in
            PaneContext(
                paneId: descriptor.id,
                sessionId: session.id,
                terminalKey: descriptor.terminalKey,
                attachOnly: descriptor.attachOnly,
                machine: .local,
                session: session,
                project: project
            )
        }
    )
}
#endif
