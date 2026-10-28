import CodevisorUI
import SwiftUI

struct SidebarRowList<Row: Equatable, ID: Hashable, Content: View>: View {
  let rows: [Row]
  let id: (Row) -> ID
  var spacing: CGFloat = 1
  let animation: Animation?
  @ViewBuilder let content: (Row) -> Content
  @State private var shown: [Shown] = []
  @State private var isPrimed = false
  @State private var progress = SidebarFoldProgress()
  @State private var batch = 0

  private struct Shown: Identifiable {
    let id: ID
    var row: Row
    var visibility: SidebarRowVisibility
  }

  var body: some View {
    let displayed = isPrimed ? shown : rows.map { Shown(id: id($0), row: $0, visibility: .shown) }
    SidebarRowStack(spacing: spacing, progress: progress, batch: batch) {
      ForEach(displayed) { item in
        content(item.row)
          .modifier(SidebarRowFoldModifier(visibility: item.visibility))
          .transition(item.visibility.isFolding && item.visibility.target == 1 ? .opacity : .identity)
      }
    }
    .animation(animation, value: displayed.map(\.id))
    .onAppear {
      shown = rows.map { Shown(id: id($0), row: $0, visibility: .shown) }
      isPrimed = true
    }
    .onChange(of: rows) { previous, current in
      if previous.map(id) == current.map(id) { refresh() } else { reconcile() }
    }
  }

  private func refresh() {
    let current = Dictionary(rows.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    shown = shown.map { Shown(id: $0.id, row: current[$0.id] ?? $0.row, visibility: $0.visibility) }
  }

  private func reconcile() {
    guard let animation else {
      shown = rows.map { Shown(id: id($0), row: $0, visibility: .shown) }
      progress = SidebarFoldProgress()
      return
    }
    let existing = Dictionary(shown.map { ($0.id, $0.row) }, uniquingKeysWith: { first, _ in first })
    let current = Dictionary(rows.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    let fold = progress.count
    let placements = SidebarRowFold.plan(
      from: shown.map { SidebarRowFold.Placement($0.id, $0.visibility) }, to: rows.map(id), fold: fold)
    let entries: [Shown] = placements.compactMap { placement in
      guard let row = current[placement.id] ?? existing[placement.id] else { return nil }
      return Shown(id: placement.id, row: row, visibility: placement.visibility)
    }
    guard entries.contains(where: { $0.visibility.terms.contains { $0.fold == fold } }) else {
      withAnimation(animation) { shown = entries }
      return
    }
    batch += 1
    let started = batch
    withAnimation(animation, completionCriteria: .removed) {
      shown = entries
      progress.advance(fold)
    } completion: {
      if batch == started { settle() }
    }
  }

  private func settle() {
    let settled = SidebarRowFold.settle(shown.map { SidebarRowFold.Placement($0.id, $0.visibility) })
    let rows = Dictionary(shown.map { ($0.id, $0.row) }, uniquingKeysWith: { first, _ in first })
    var transaction = Transaction()
    transaction.disablesAnimations = true
    withTransaction(transaction) {
      shown = settled.compactMap { placement in
        rows[placement.id].map { Shown(id: placement.id, row: $0, visibility: .shown) }
      }
      progress = SidebarFoldProgress()
    }
  }
}

nonisolated private struct SidebarRowVisibilityKey: LayoutValueKey {
  static let defaultValue = SidebarRowVisibility.shown
}

private struct SidebarRowFoldModifier: ViewModifier {
  let visibility: SidebarRowVisibility

  func body(content: Content) -> some View {
    let isLeaving = visibility.target == 0
    SidebarRowClip { content }
      .clipped()
      .opacity(isLeaving ? 0 : 1)
      .allowsHitTesting(!isLeaving)
      .accessibilityHidden(isLeaving)
      .zIndex(visibility.isFolding ? 0 : 1)
      .layoutValue(key: SidebarRowVisibilityKey.self, value: visibility)
  }
}

private struct SidebarRowStack: Layout {
  var spacing: CGFloat
  var progress: SidebarFoldProgress
  var batch: Int

  var animatableData: SidebarFoldProgress {
    get { progress }
    set { progress = newValue }
  }

  struct Cache {
    var width: CGFloat?
    var batch: Int?
    var sizes: [CGSize] = []
  }

  func makeCache(subviews: Subviews) -> Cache { Cache() }

  func updateCache(_ cache: inout Cache, subviews: Subviews) {
    cache.sizes = []
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) -> CGSize {
    let layout = layout(subviews, width: proposal.width, cache: &cache)
    return CGSize(width: layout.frames.map(\.maxX).max() ?? proposal.width ?? 0, height: layout.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout Cache) {
    for (subview, frame) in zip(subviews, layout(subviews, width: bounds.width, cache: &cache).frames) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: frame.height)
      )
    }
  }

  private func sizes(of subviews: Subviews, width: CGFloat?, cache: inout Cache) -> [CGSize] {
    if progress.isFolding, cache.batch == batch, cache.width == width, cache.sizes.count == subviews.count {
      return cache.sizes
    }
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    cache = Cache(width: width, batch: batch, sizes: sizes)
    return sizes
  }

  private func layout(
    _ subviews: Subviews, width: CGFloat?, cache: inout Cache
  ) -> (frames: [CGRect], height: CGFloat) {
    let sizes = sizes(of: subviews, width: width, cache: &cache)
    let visibilities = subviews.map { $0[SidebarRowVisibilityKey.self] }
    var blocks: [Range<Int>] = []
    for index in visibilities.indices {
      if let last = blocks.last, visibilities[index].isFolding, visibilities[last.lowerBound] == visibilities[index] {
        blocks[blocks.count - 1] = last.lowerBound..<(index + 1)
      } else {
        blocks.append(index..<(index + 1))
      }
    }
    var frames = sizes.map { CGRect(origin: .zero, size: $0) }
    var y: CGFloat = 0
    var gapTaken = false
    for (number, block) in blocks.enumerated() {
      let visibility = visibilities[block.lowerBound]
      let hasPrevious = number > 0
      guard visibility.isFolding else {
        if hasPrevious && !gapTaken { y += spacing }
        frames[block.lowerBound].origin.y = y
        y += sizes[block.lowerBound].height
        gapTaken = false
        continue
      }
      let shown = visibility.value(at: progress)
      let lead = hasPrevious && !gapTaken ? spacing : 0
      let trail = !hasPrevious && number < blocks.count - 1 ? spacing : 0
      let height = block.map { sizes[$0].height }.reduce(0, +) + spacing * CGFloat(block.count - 1)
      let bottom = y + (lead + height + trail) * shown
      var rowY = y + lead
      for index in block {
        frames[index].origin.y = rowY
        frames[index].size.height = min(sizes[index].height, max(0, bottom - rowY))
        rowY += sizes[index].height + spacing
      }
      y = bottom
      gapTaken = trail > 0
    }
    return (frames, y)
  }
}

struct SidebarRowClip: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    let size = content.sizeThatFits(ProposedViewSize(width: proposal.width, height: nil))
    return CGSize(width: size.width, height: min(size.height, proposal.height ?? size.height))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(
      at: bounds.origin, anchor: .topLeading, proposal: ProposedViewSize(width: bounds.width, height: nil))
  }
}
