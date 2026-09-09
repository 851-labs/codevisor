import CodevisorCore
import CodevisorUI
import SwiftUI

/// What the sidebar asks its owner to do. Rows only request changes; the
/// owner routes chats, edits layouts, and archives.
struct HomeSidebarActions {
  var open: (HomeSidebarTabRow, HomeSidebarSection) -> Void = { _, _ in }
  var close: (HomeSidebarTabRow, HomeSidebarSection) -> Void = { _, _ in }
  var rename: (HomeSidebarTabRow, HomeSidebarSection) -> Void = { _, _ in }
  var newTab: (HomeSidebarSection) -> Void = { _ in }
  var renameWorkspace: (HomeSidebarSection) -> Void = { _ in }
  var archiveWorkspace: (HomeSidebarSection) -> Void = { _ in }
  /// The workspace ids in their new order after a drag-to-reorder drop.
  var reorder: ([UUID]) -> Void = { _ in }
}

/// The sidebar: one always-expanded section per workspace listing its tabs.
///
/// Reordering is a single gesture on a workspace header: a long press lifts
/// it, every card collapses to its header so the list is just names, the
/// drag moves it live past the other names, and the drop commits the order
/// and expands the cards again. The whole thing happens inside this one
/// `List` — swapping to a separate reorder view would end the gesture.
///
/// The lifted header is drawn as an overlay on the list, positioned only by
/// the finger; its own section keeps an invisible placeholder. That keeps it
/// out of the reflow animation entirely — only the other headers animate
/// past, and the hole slides under the finger.
struct HomeSidebarList: View {
  let sections: [HomeSidebarSection]
  let actions: HomeSidebarActions
  let refresh: () async -> Void

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drag: WorkspaceDrag?
  /// Header slot frames, measured on a wrapper that is NOT offset with the
  /// lifted header. Global space: `List` hosts each cell separately, so a
  /// named space declared on the list does not resolve inside the cells,
  /// and the finger and the frames must agree. Scrolling is suspended while
  /// something is lifted, so global stays stable for the drag.
  @State private var headerFrames: [UUID: CGRect] = [:]
  /// The list's own global frame, to place the floating header in it.
  @State private var listFrame: CGRect = .zero
  @GestureState private var isPressing = false
  @State private var liftFeedback = 0

  private struct WorkspaceDrag: Equatable {
    let id: UUID
    var order: [UUID]
    /// Where the header's center was when it lifted. Until the first drag
    /// sample this is where the finger is, so the floating header stays put
    /// while the cards collapse under it.
    let liftedMidY: CGFloat
    var fingerY: CGFloat?
    /// Where on the header the finger landed, relative to its center, so
    /// the header lifts in place instead of snapping its center under the
    /// finger.
    var grabOffset: CGFloat?
    /// Released: the floating header is gliding into its slot before the
    /// cards expand.
    var isSettling = false
  }

  private var displayedSections: [HomeSidebarSection] {
    guard let drag else { return sections }
    let byID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return drag.order.compactMap { byID[$0] }
  }

  var body: some View {
    List {
      ForEach(displayedSections) { section in
        Section {
          if drag == nil {
            ForEach(section.rows) { row in
              HomeSidebarTabRowView(
                row: row,
                serverId: section.serverId,
                onOpen: { actions.open(row, section) },
                onClose: { actions.close(row, section) },
                onRename: row.renamableTabId == nil ? nil : { actions.rename(row, section) }
              )
            }
            if section.rows.isEmpty {
              Text("No tabs")
                .foregroundStyle(.tertiary)
            }
          }
        } header: {
          header(section)
        }
      }
    }
    .listStyle(.insetGrouped)
    .scrollDisabled(drag != nil)
    .animation(Motion.listReflow(reduceMotion: reduceMotion), value: drag?.order)
    .onGeometryChange(for: CGRect.self) { proxy in
      proxy.frame(in: .global)
    } action: { frame in
      listFrame = frame
    }
    // Outside the reflow animation above: the floating header answers the
    // finger immediately.
    .overlay(alignment: .topLeading) {
      floatingHeader
    }
    // The collapse moves every slot; keep the hole under the finger as
    // they settle, not only when the finger itself moves.
    .onChange(of: headerFrames) { _, _ in
      reconcileOrder()
    }
    .sensoryFeedback(.impact(weight: .medium), trigger: liftFeedback)
    .sensoryFeedback(.selection, trigger: drag?.order)
    // A cancelled gesture (a system interruption mid-drag) never reports
    // `onEnded`; the press state resetting is the reliable release signal.
    .onChange(of: isPressing) { _, pressing in
      if !pressing { endDrag() }
    }
    .refreshable {
      await refresh()
    }
  }

  private func header(_ section: HomeSidebarSection) -> some View {
    let isLifted = drag?.id == section.id
    return ZStack {
      // The measured slot: stays put while the header itself is offset.
      Color.clear
        .onGeometryChange(for: CGRect.self) { proxy in
          proxy.frame(in: .global)
        } action: { frame in
          headerFrames[section.id] = frame
        }
      HomeSidebarSectionHeader(
        section: section,
        isReordering: drag != nil,
        onNewTab: { actions.newTab(section) },
        onRename: { actions.renameWorkspace(section) },
        onArchive: { actions.archiveWorkspace(section) }
      )
      // The lifted header's own slot is an invisible placeholder; the
      // floating copy is what the user sees moving.
      .opacity(isLifted ? 0 : drag != nil ? 0.55 : 1)
    }
    .contentShape(Rectangle())
    .gesture(reorderGesture(for: section))
  }

  /// The lifted header in the list's coordinate space: pinned where it
  /// lifted until the finger moves, then under the finger (grab point
  /// kept), and gliding onto its live slot while settling.
  @ViewBuilder
  private var floatingHeader: some View {
    if let drag,
      let section = sections.first(where: { $0.id == drag.id }),
      let slot = headerFrames[drag.id]
    {
      let centerY = drag.isSettling ? slot.midY : liftedCenterY(drag)
      HomeSidebarSectionHeader(
        section: section,
        isReordering: true,
        onNewTab: {},
        onRename: {},
        onArchive: {}
      )
      .frame(width: slot.width, height: slot.height)
      .scaleEffect(drag.isSettling ? 1 : 1.03)
      .offset(
        x: slot.minX - listFrame.minX,
        y: centerY - slot.height / 2 - listFrame.minY
      )
      .allowsHitTesting(false)
      .transition(.identity)
    }
  }

  private func reorderGesture(for section: HomeSidebarSection) -> some Gesture {
    LongPressGesture(minimumDuration: 0.35)
      .sequenced(
        before: DragGesture(minimumDistance: 0, coordinateSpace: .global)
      )
      .updating($isPressing) { value, pressing, _ in
        if case .second(true, _) = value { pressing = true }
      }
      .onChanged { value in
        guard case let .second(true, dragValue) = value else { return }
        if drag == nil { beginDrag(section) }
        if let dragValue { updateDrag(fingerY: dragValue.location.y) }
      }
      .onEnded { _ in
        endDrag()
      }
  }

  private func beginDrag(_ section: HomeSidebarSection) {
    liftFeedback += 1
    withAnimation(.snappy(duration: 0.28)) {
      drag = WorkspaceDrag(
        id: section.id,
        order: sections.map(\.id),
        liftedMidY: headerFrames[section.id]?.midY ?? 0,
        fingerY: nil,
        grabOffset: nil
      )
    }
  }

  /// The floating header's center: the lift point until the finger moves,
  /// then the finger less where on the header it grabbed.
  private func liftedCenterY(_ drag: WorkspaceDrag) -> CGFloat {
    guard let fingerY = drag.fingerY else { return drag.liftedMidY }
    return fingerY - (drag.grabOffset ?? 0)
  }

  private func updateDrag(fingerY: CGFloat) {
    guard var current = drag, !current.isSettling else { return }
    if current.grabOffset == nil {
      // Measured against the frozen lift point: the slot has already
      // started moving with the collapse, the finger has not.
      current.grabOffset = fingerY - current.liftedMidY
    }
    current.fingerY = fingerY
    drag = current
    reconcileOrder()
  }

  /// Slot the lifted workspace after every other header its center has
  /// passed. Compares header centers to the lifted header's center rather
  /// than the fingertip, so where you grabbed it doesn't bias the crossing.
  private func reconcileOrder() {
    guard var current = drag, !current.isSettling else { return }
    let liftedMidY = liftedCenterY(current)
    let others = current.order.filter { $0 != current.id }
    let passed = others.filter { id in
      guard let frame = headerFrames[id] else { return false }
      return frame.midY < liftedMidY
    }.count
    var order = others
    order.insert(current.id, at: min(passed, others.count))
    guard order != current.order else { return }
    current.order = order
    drag = current
  }

  /// Commit the order, glide the floating header onto its slot, then let
  /// the cards expand.
  private func endDrag() {
    guard var current = drag, !current.isSettling else { return }
    if current.order != sections.map(\.id) {
      actions.reorder(current.order)
    }
    current.isSettling = true
    current.fingerY = nil
    let settle = reduceMotion ? 0.0 : 0.22
    withAnimation(.snappy(duration: settle)) {
      drag = current
    }
    Task { @MainActor in
      try? await Task.sleep(for: .seconds(settle))
      guard drag?.id == current.id, drag?.isSettling == true else { return }
      withAnimation(.snappy(duration: 0.28)) {
        drag = nil
      }
    }
  }
}
