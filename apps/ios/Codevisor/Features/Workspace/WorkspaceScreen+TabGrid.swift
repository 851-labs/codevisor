import CodevisorCore
import CodevisorUI
import SwiftUI
import UIKit

// MARK: - Tab grid (the workspace's base)

extension WorkspaceScreen {
  /// The Safari-style tab switcher: a two-column grid of pane previews with
  /// close buttons.
  var grid: some View {
    WorkspaceTabGridView(
      panes: panes.panes,
      paneStorageId: paneStorageId,
      gridDrag: gridDrag,
      gridDragGestureIsActive: gridDragGestureIsActive,
      gridLiftFeedback: gridLiftFeedback,
      pendingNewTabZoomPaneId: pendingNewTabZoomPaneId,
      showsGrid: showsGrid,
      pluginIconClient: environment.machines.client(for: resolvedServerId),
      pluginIconCacheNamespace: resolvedServerId,
      title: { title(for: $0) },
      onSelect: { pane in
        guard gridDrag == nil,
          suppressedPaneTapId != pane.id
        else { return }
        select(pane)
      },
      onClose: { close($0) },
      moveAction: { moveAction(for: $0, offset: $1) },
      reorderGesture: { paneReorderGesture(for: $0) },
      onPaneCardFrames: { frames in
        paneCardFrames = frames
        startPendingGridZoomIfPossible()
        startPendingNewTabZoomIfPossible()
      },
      onDragGestureEnded: { finishGridDrag() },
      onGridHidden: {
        gridDrag = nil
        suppressedPaneTapId = nil
      }
    )
  }

  private func paneReorderGesture(
    for pane: PaneDescriptorState
  ) -> some Gesture {
    LongPressGesture(minimumDuration: 0.18, maximumDistance: 12)
      .sequenced(
        before: DragGesture(
          minimumDistance: 0,
          coordinateSpace: .global
        )
      )
      .updating($gridDragGestureIsActive) { phase, isActive, _ in
        if case .second(true, _) = phase {
          isActive = true
        }
      }
      .onChanged { phase in
        guard case let .second(true, value) = phase,
          let value
        else { return }
        updateGridDrag(for: pane, value: value)
      }
  }

  private func updateGridDrag(
    for pane: PaneDescriptorState,
    value: DragGesture.Value
  ) {
    if gridDrag == nil {
      guard
        let frame = paneCardFrames[pane.id],
        let currentSlotIndex = panes.panes.firstIndex(where: {
          $0.id == pane.id
        })
      else { return }
      let slots = panes.panes.enumerated().compactMap { index, pane in
        paneCardFrames[pane.id].map {
          WorkspaceTabGridSlot(index: index, frame: $0)
        }
      }
      let snapshot = paneStorageId.flatMap {
        PaneSnapshotCache.shared.image(for: pane.id, in: $0)
      }
      gridDrag = WorkspaceTabGridDragState(
        pane: pane,
        title: title(for: pane),
        snapshot: snapshot,
        size: frame.size,
        grabOffset: CGSize(
          width: min(max(value.startLocation.x - frame.minX, 0), frame.width),
          height: min(max(value.startLocation.y - frame.minY, 0), frame.height)
        ),
        slots: slots,
        currentSlotIndex: currentSlotIndex,
        fingerLocation: value.location,
        liftProgress: 0
      )
      suppressedPaneTapId = pane.id
      gridLiftFeedback += 1

      Task { @MainActor in
        await Task.yield()
        guard var drag = gridDrag, drag.pane.id == pane.id else { return }
        drag.liftProgress = 1
        withAnimation(WorkspaceTabGridMotion.lift) {
          gridDrag = drag
        }
      }
    }

    guard var drag = gridDrag, drag.pane.id == pane.id else { return }
    drag.fingerLocation = value.location
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      gridDrag = drag
    }

    let liftedCenter = CGPoint(
      x: value.location.x - drag.grabOffset.width + drag.size.width / 2,
      y: value.location.y - drag.grabOffset.height + drag.size.height / 2
    )
    reorderDraggedPane(pane.id, nearestTo: liftedCenter)
  }

  private func reorderDraggedPane(_ paneId: UUID, nearestTo point: CGPoint) {
    guard var drag = gridDrag, drag.pane.id == paneId,
      let targetIndex = WorkspaceTabGridReorderContract.targetIndex(
        currentIndex: drag.currentSlotIndex,
        point: point,
        slots: drag.slots
      ),
      panes.panes.indices.contains(targetIndex),
      panes.panes[targetIndex].id != paneId
    else { return }

    let targetPaneId = panes.panes[targetIndex].id
    drag.currentSlotIndex = targetIndex
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      gridDrag = drag
    }
    reorderPane(paneId, onto: targetPaneId)
  }

  /// Springs the still-opaque lifted tile onto the current empty slot. Only
  /// once both occupy identical geometry do we remove the overlay and
  /// reveal the real card beneath it.
  private func finishGridDrag() {
    guard let paneId = gridDrag?.pane.id else { return }
    Task { @MainActor in
      await Task.yield()
      guard var drag = gridDrag, drag.pane.id == paneId else { return }
      guard
        let target = drag.slots.first(where: {
          $0.index == drag.currentSlotIndex
        })?.frame
      else {
        clearGridDrag(paneId: paneId)
        return
      }

      drag.fingerLocation = CGPoint(
        x: target.minX + drag.grabOffset.width,
        y: target.minY + drag.grabOffset.height
      )
      drag.liftProgress = 0
      withAnimation(WorkspaceTabGridMotion.release) {
        gridDrag = drag
      }
      try? await Task.sleep(for: .milliseconds(340))
      clearGridDrag(paneId: paneId)
    }
  }

  private func clearGridDrag(paneId: UUID) {
    guard gridDrag?.pane.id == paneId else { return }
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      gridDrag = nil
    }
    Task { @MainActor in
      await Task.yield()
      if suppressedPaneTapId == paneId {
        suppressedPaneTapId = nil
      }
    }
  }

  var paneBinding: Binding<PaneGroupState> {
    Binding(
      get: { panes },
      set: { newValue in
        paneState = newValue
        persistCompactPaneState(newValue)
      }
    )
  }

  func paneContent(_ pane: PaneDescriptorState) -> some View {
    WorkspacePaneContentView(
      pane: pane,
      chatController: { chatController(for: $0) },
      activeSessionId: activeSessionId,
      session: { session(for: $0) },
      projectList: environment.projectList,
      showsRunPickers: isDraft && !hasStarted,
      initialComposerFocusRequest: initialComposerFocusRequest,
      onInitialComposerFocusRequestFulfilled:
        onInitialComposerFocusRequestFulfilled,
      transcriptPresentationRole: transcriptPresentationRole,
      onSendAnimationCompleted: onSendAnimationCompleted,
      onSendAnimationStarted: onSendAnimationStarted,
      onComposerWillSend: onComposerWillSend,
      preservesComposerFocusOnSend: isNewChatPresentation
        && !isFirstSendPromotionSurface,
      composerTextEditorHandoffRole: composerTextEditorHandoffRole,
      composerTextEditorHandoffID: composerTextEditorHandoffID,
      isNewChatPresentation: isNewChatPresentation,
      hasStarted: hasStarted,
      onWorkspaceReady: onWorkspaceReady,
      connectChat: { await connectChat(sessionId: $0) },
      onConvertToChat: { convertToChat(pane) },
      onConvertToTerminal: { convertToTerminal(pane) },
      onConvertToPlugin: { convertToPlugin(pane, option: $0) },
      serverConfig: serverConfig,
      workspaceCwd: workspaceCwd,
      machineClient: environment.machines.client(for: resolvedServerId),
      machineId: resolvedServerId,
      pluginPaneModel: { pluginPaneModel(for: $0) },
      onRenamePane: { renamePane($0, to: $1) }
    )
  }

  /// The pane's cached plugin model — the webview and its load state
  /// survive tab switches; the cache tears down webviews for panes that
  /// leave the active canvas.
  private func pluginPaneModel(for pane: PaneDescriptorState) -> PluginPaneModel {
    let serverId = resolvedServerId
    let machines = environment.machines
    return PluginPaneCache.shared.model(for: pane.id) {
      PluginPaneModel(
        paneId: pane.id,
        serverId: serverId,
        pluginId: pane.pluginId ?? "",
        paneType: pane.pluginPaneType ?? "",
        workspaceId: resolvedWorkspace?.id,
        cwd: workspaceCwd,
        client: machines.client(for: serverId),
        resolveBaseURL: { [weak machines] in
          await machines?.effectiveHTTPBaseURL(forMachineId: serverId)
        }
      )
    }
  }

  /// `codevisor.setTitle` from a plugin pane: rename the tab like a manual
  /// rename would (persisted + published), matching macOS.
  private func renamePane(_ pane: PaneDescriptorState, to name: String) {
    let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
    var state = panes
    guard !trimmed.isEmpty,
      let index = state.panes.firstIndex(where: { $0.id == pane.id }),
      state.panes[index].name != trimmed
    else { return }
    state.panes[index].name = trimmed
    paneBinding.wrappedValue = state
    publishPane(state.panes[index])
  }
}
