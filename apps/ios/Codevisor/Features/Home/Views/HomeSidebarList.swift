import CodevisorCore
import CodevisorUI
import SwiftUI

struct HomeSidebarActions {
  var open: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var close: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var rename: (HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void = { _, _ in }
  var newTab: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var renameWorkspace: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var archiveWorkspace: (HomeSidebarWorkspaceRef) -> Void = { _ in }
  var reorder: (UUID, [UUID]) -> Void = { _, _ in }
  var moveTab: (UUID, UUID?, HomeSidebarWorkspaceRef) -> Void = { _, _, _ in }
  var openInNewWindow: ((HomeSidebarTabRow, HomeSidebarWorkspaceRef) -> Void)?
  var didSelectInSplit: () -> Void = {}
  var refresh: () async -> Void = {}
}

@MainActor
final class HomeSidebarActionHandler {
  var actions: HomeSidebarActions

  init(_ actions: HomeSidebarActions) {
    self.actions = actions
  }
}

struct HomeSidebarList: View {
  let sections: [HomeSidebarSection]
  let actions: HomeSidebarActionHandler
  var selection: Binding<UUID?>? = nil

  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var drag: WorkspaceDrag?
  @State private var headerFrames: [UUID: CGRect] = [:]
  @State private var rowBottoms = HomeSidebarRowBottoms()
  @State private var listFrame: CGRect = .zero
  @State private var liftFeedback = 0

  private struct WorkspaceDrag: Equatable {
    let id: UUID
    var order: [UUID]
    let liftedMidY: CGFloat
    var fingerY: CGFloat?
    var grabOffset: CGFloat?
    var isSettling = false
  }

  private var displayedSections: [HomeSidebarSection] {
    guard let drag else { return sections }
    let byID = Dictionary(sections.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    return drag.order.compactMap { byID[$0] }
  }

  @ViewBuilder
  private func sectionContent(isSelectionList: Bool) -> some View {
    ForEach(displayedSections) { section in
      Section {
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
      .overlay(alignment: .topLeading) {
        floatingHeader
      }
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

  private func liftedCenterY(_ drag: WorkspaceDrag) -> CGFloat {
    guard let fingerY = drag.fingerY else { return drag.liftedMidY }
    return fingerY - (drag.grabOffset ?? 0)
  }

  private func updateDrag(fingerY: CGFloat) {
    guard var current = drag, !current.isSettling else { return }
    if current.grabOffset == nil {
      current.grabOffset = fingerY - current.liftedMidY
    }
    current.fingerY = fingerY
    drag = current
    reconcileOrder()
  }

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
