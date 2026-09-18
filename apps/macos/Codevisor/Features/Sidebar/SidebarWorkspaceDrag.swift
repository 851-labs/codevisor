//  Drag-to-reorder for the sidebar's workspace sections.
//
//  The system drag session (`.draggable`/`.onDrop`) was replaced on purpose:
//  its preview is owned by AppKit, which slides it back to the drag's ORIGIN
//  whenever the pointer is released off a drop target, while the row itself
//  had already reflowed live to its new slot. Here the app draws the ghost,
//  so on release it flies onto the row's actual frame and crossfades away.

import CodevisorCore
import CodevisorUI
import SwiftUI

/// Where a workspace section sits, in the sidebar's reorder coordinate space.
struct SidebarWorkspaceGeometry: Equatable {
  /// The header row alone: what the ghost mimics and lands on.
  var header: CGRect = .zero
  /// The header plus its tab rows: what the ghost is compared against.
  var section: CGRect = .zero
}

/// Frames reported by every mounted section. A plain class, deliberately
/// not observed: frames change on every scroll tick and must not
/// re-evaluate the sidebar; the drag reads them on demand.
@MainActor
final class SidebarWorkspaceGeometryStore {
  var frames: [UUID: SidebarWorkspaceGeometry] = [:]
}

/// A workspace header lifted from the list and following the pointer.
struct SidebarWorkspaceDrag: Equatable {
  let workspaceID: UUID
  /// The header's frame when it was lifted.
  let liftedFrame: CGRect
  var translation: CGFloat = 0
  /// Set on release: the ghost is flying onto `settleFrame`, the row's
  /// current frame, which keeps tracking a reflow still in flight.
  var settleFrame: CGRect?

  var isSettling: Bool { settleFrame != nil }

  var ghostFrame: CGRect {
    settleFrame ?? liftedFrame.offsetBy(dx: 0, dy: translation)
  }
}

extension SidebarView {
  static let reorderSpace = "sidebar.reorder"

  var draggingWorkspaceID: UUID? { workspaceDrag?.workspaceID }

  /// Non-nil while the released ghost is landing; drives the cleanup task.
  var settlingWorkspaceID: UUID? {
    workspaceDrag.flatMap { $0.isSettling ? $0.workspaceID : nil }
  }

  func workspaceReorderGesture(for id: UUID) -> some Gesture {
    // Measured in the sidebar's space, not the header's own: the header
    // moves when the list reflows beneath it, and a local translation
    // would shrink by exactly that displacement.
    DragGesture(minimumDistance: 4, coordinateSpace: .named(Self.reorderSpace))
      .onChanged { value in
        if workspaceDrag?.workspaceID != id || workspaceDrag?.isSettling == true {
          guard let header = workspaceGeometry.frames[id]?.header, header != .zero else { return }
          workspaceDrag = SidebarWorkspaceDrag(workspaceID: id, liftedFrame: header)
        }
        workspaceDrag?.translation = value.translation.height
        moveDraggedWorkspace()
      }
      .onEnded { value in
        guard let drag = workspaceDrag, !drag.isSettling else { return }
        // A fast release can carry movement past the last `onChanged`;
        // apply it so the drop lands where the pointer actually let go.
        workspaceDrag?.translation = value.translation.height
        moveDraggedWorkspace()
        workspaceDrag?.settleFrame = workspaceGeometry.frames[drag.workspaceID]?.header ?? drag.liftedFrame
      }
  }

  func recordWorkspaceHeaderFrame(_ frame: CGRect, for id: UUID) {
    workspaceGeometry.frames[id, default: .init()].header = frame
    // The one geometry change that must reach the view: a settling ghost
    // retargets onto its row as the reflow finishes.
    if workspaceDrag?.workspaceID == id, workspaceDrag?.isSettling == true {
      workspaceDrag?.settleFrame = frame
    }
  }

  func recordWorkspaceSectionFrame(_ frame: CGRect, for id: UUID) {
    workspaceGeometry.frames[id, default: .init()].section = frame
  }

  func forgetWorkspaceGeometry(for id: UUID) {
    workspaceGeometry.frames[id] = nil
  }

  private func moveDraggedWorkspace() {
    guard let drag = workspaceDrag, !drag.isSettling else { return }
    let order = workspaceItems.map(\.workspace.id)
    let sections = workspaceGeometry.frames.compactMapValues {
      $0.section == .zero ? nil : $0.section
    }
    guard
      let index = ListReorder.destinationIndex(
        of: drag.workspaceID, in: order, frames: sections, midY: drag.ghostFrame.midY
      )
    else { return }
    moveWorkspace(drag.workspaceID, toIndex: index)
  }

  /// Once the ghost has landed, remove it while the dimmed row fades back
  /// in underneath — the two overlap exactly, so the swap is invisible.
  func finishSettledWorkspaceDrag() async {
    guard settlingWorkspaceID != nil else { return }
    if !reduceMotion {
      try? await Task.sleep(for: .seconds(Motion.listReflowDuration))
    }
    guard !Task.isCancelled else { return }
    withAnimation(Motion.quick(reduceMotion: reduceMotion)) {
      workspaceDrag = nil
    }
  }

  @ViewBuilder
  var workspaceReorderGhost: some View {
    if let drag = workspaceDrag,
      let item = workspaceItems.first(where: { $0.workspace.id == drag.workspaceID })
    {
      let frame = drag.ghostFrame
      SidebarWorkspaceDragGhost(
        name: item.workspace.name,
        machineName: machineName(for: item)
      )
      .frame(width: frame.width, height: frame.height)
      .position(x: frame.midX, y: frame.midY)
      .animation(drag.isSettling ? Motion.listReflow(reduceMotion: reduceMotion) : nil, value: frame)
      .transition(.opacity)
      .allowsHitTesting(false)
    }
  }
}

/// The lifted header's stand-in: the header exactly as it renders in the
/// list — same label, insets, and color, no added chrome — so lifting and
/// landing read as the row itself moving.
struct SidebarWorkspaceDragGhost: View {
  let name: String
  let machineName: String?

  var body: some View {
    HStack(spacing: 0) {
      SidebarWorkspaceHeaderLabel(name: name, machineName: machineName)
      Spacer(minLength: 0)
    }
    .foregroundStyle(.secondary)
    .padding(.horizontal, SidebarWorkspaceHeader.horizontalPadding)
    .padding(.top, SidebarWorkspaceHeader.topPadding)
    .padding(.bottom, SidebarWorkspaceHeader.bottomPadding)
  }
}
