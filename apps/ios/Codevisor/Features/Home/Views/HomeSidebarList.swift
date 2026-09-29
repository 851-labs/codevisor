import CodevisorCore
import CodevisorUI
import SwiftUI

/// What the sidebar asks its owner to do. Rows only request changes; the
/// owner routes chats, edits layouts, and archives.
struct HomeSidebarActions {
  var open: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var close: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var rename: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var newTab: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var renameWorkspace: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var archiveWorkspace: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  /// The workspace ids in their new order after a drag-to-reorder drop.
  var reorder: (UUID, [UUID]) -> Void = { _, _ in }
  /// A tab dragged within its workspace: the tab and the one it now sits
  /// in front of (nil at the end).
  var moveTab: (UUID, UUID?, HomeSidebarWorkspaceRef) -> Void = { _, _, _ in }
  /// Nil where the device shows one window at a time (iPhone).
  var openInNewWindow: ((HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void)?
  /// A split-layout selection landed; an overlay sidebar gets out of the way.
  var didSelectInSplit: () -> Void = {}
  var refresh: () async -> Void = {}
}

/// The sidebar's actions behind a stable reference. Rows compare it by
/// identity, so a parent re-render that only rebuilt the closures leaves
/// unchanged rows alone.
@MainActor
final class HomeSidebarActionHandler {
  var actions: HomeSidebarActions

  init(_ actions: HomeSidebarActions) {
    self.actions = actions
  }
}

/// The sidebar: one always-expanded section per workspace listing its tabs.
///
/// Reordering is a single gesture on a workspace header: a long press lifts
/// it and collapses just that workspace to its header, the drag moves it
/// live past the other workspaces (which keep their tabs showing), and the
/// drop commits the order and expands it again. The whole thing happens inside this one
/// `List` — swapping to a separate reorder view would end the gesture.
///
/// The lifted header is drawn as an overlay on the list, positioned only by
/// the finger; its own section keeps an invisible placeholder. That keeps it
/// out of the reflow animation entirely — only the other headers animate
/// past, and the hole slides under the finger.
struct HomeSidebarList: View {
  let sections: [HomeSidebarSection]
  let actions: HomeSidebarActionHandler
  /// The split layout's selection, by pane id. Present, the list is a
  /// native `.sidebar` selection list; absent, it is the phone's grouped
  /// list of buttons that push.
  var selection: Binding<UUID?>? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drag: WorkspaceDrag?
  /// Header slot frames, measured on a wrapper that is NOT offset with the
  /// lifted header. Global space: `List` hosts each cell separately, so a
  /// named space declared on the list does not resolve inside the cells,
  /// and the finger and the frames must agree. Scrolling is suspended while
  /// something is lifted, so global stays stable for the drag.
  @State private var headerFrames: [UUID: CGRect] = [:]
  /// Where each section's rows end, so a lifted header crosses a whole
  /// section rather than just its header.
  @State private var rowBottoms = HomeSidebarRowBottoms()
  /// The list's own global frame, to place the floating header in it.
  @State private var listFrame: CGRect = .zero
  @State private var liftFeedback = 0

  private struct WorkspaceDrag: Equatable {
    let id: UUID
    var order: [UUID]
    /// Where the header's center was when it lifted. Until the first drag
    /// sample this is where the finger is, so the floating header stays put
    /// while its own tabs collapse under it.
    let liftedMidY: CGFloat
    var fingerY: CGFloat?
    /// Where on the header the finger landed, relative to its center, so
    /// the header lifts in place instead of snapping its center under the
    /// finger.
    var grabOffset: CGFloat?
    /// Released: the floating header is gliding into its slot before its
    /// tabs expand.
    var isSettling = false
  }

  private var displayedSections: [HomeSidebarSection] {
    guard let drag else { return sections }
    let byID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return drag.order.compactMap { byID[$0] }
  }

  /// The sections, shared by both list styles.
  @ViewBuilder
  private func sectionContent(isSelectionList: Bool) -> some View {
    ForEach(displayedSections) { section in
      Section {
        // Only the lifted workspace collapses to its header.
        if drag?.id != section.id {
          let workspace = section.workspace
          ForEach(section.rows) { row in
            HomeSidebarTabRowView(
              row: row,
              workspace: workspace,
              actions: actions,
              isSelectionRow: isSelectionList
            )
            .equatable()
            .tag(row.id)
            .onGeometryChange(for: CGFloat.self) { proxy in
              proxy.frame(in: .global).maxY
            } action: { maxY in
              rowBottoms.record(maxY, row: row.id, section: section.id)
            }
            .onDisappear { rowBottoms.forget(row: row.id, section: section.id) }
          }
          // The system's own row drag: long press, lift, drop. Rows of a
          // split belong to one tab, so moving any of them moves the tab.
          .onMove { source, destination in
            moveTab(in: section, from: source, to: destination)
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

  private func moveTab(in section: HomeSidebarSection, from source: IndexSet, to destination: Int) {
    guard let row = source.first, let tabId = section.rows[row].tabId else { return }
    let rowTabIds = section.rows.map { $0.tabId ?? $0.id }
    let successor = SharedTabOrder.successor(of: tabId, droppedAt: destination, rowTabIds: rowTabIds)
    actions.actions.moveTab(tabId, successor, section.workspace)
  }

  /// The split layout uses the platform sidebar: its selection highlight,
  /// spacing, overlay dismissal, and swipe handling are the system's. The
  /// phone keeps its grouped cards.
  @ViewBuilder
  private var styledList: some View {
    if let selection {
      List(selection: selection) {
        sectionContent(isSelectionList: true)
      }
      .listStyle(.sidebar)

    } else {
      List {
        sectionContent(isSelectionList: false)
      }
      .listStyle(.insetGrouped)
    }
  }

  var body: some View {
    styledList
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
      .refreshable {
        await actions.actions.refresh()
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
        onNewTab: { actions.actions.newTab(section.workspace) },
        onRename: { actions.actions.renameWorkspace(section.workspace) },
        onArchive: { actions.actions.archiveWorkspace(section.workspace) }
      )
      // The lifted header's own slot is an invisible placeholder; the
      // floating copy is what the user sees moving.
      .opacity(isLifted ? 0 : 1)
    }
    .contentShape(Rectangle())
    .gesture(
      WorkspaceReorderGesture(
        onBegan: { point in
          beginDrag(section)
          updateDrag(fingerY: point.y)
        },
        onChanged: { point in updateDrag(fingerY: point.y) },
        onEnded: endDrag
      ))
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

  /// Slot the lifted workspace after every other section whose middle its
  /// center has passed. Sections span their header and tabs, so a tall one
  /// is crossed halfway down its tabs. Compares against the lifted header's
  /// center rather than the fingertip, so where you grabbed it doesn't bias
  /// the crossing.
  private func reconcileOrder() {
    guard var current = drag, !current.isSettling else { return }
    let liftedMidY = liftedCenterY(current)
    let others = current.order.filter { $0 != current.id }
    let passed = others.filter { id in
      guard let header = headerFrames[id] else { return false }
      let bottom = max(header.maxY, rowBottoms.bottom(of: id) ?? header.maxY)
      return (header.minY + bottom) / 2 < liftedMidY
    }.count
    var order = others
    order.insert(current.id, at: min(passed, others.count))
    guard order != current.order else { return }
    current.order = order
    drag = current
  }

  /// Commit the order, glide the floating header onto its slot, then let
  /// its tabs expand again.
  private func endDrag() {
    guard var current = drag, !current.isSettling else { return }
    if current.order != sections.map(\.id) {
      actions.actions.reorder(current.id, current.order)
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

/// The lowest row edge of each section, in global space. A plain class,
/// deliberately not observed: rows move on every scroll tick and must not
/// re-render the list; the drag reads the values on demand.
@MainActor
final class HomeSidebarRowBottoms {
  private var bottoms: [UUID: [UUID: CGFloat]] = [:]

  func record(_ maxY: CGFloat, row: UUID, section: UUID) {
    bottoms[section, default: [:]][row] = maxY
  }

  func forget(row: UUID, section: UUID) {
    bottoms[section]?[row] = nil
  }

  func bottom(of section: UUID) -> CGFloat? {
    bottoms[section]?.values.max()
  }
}
