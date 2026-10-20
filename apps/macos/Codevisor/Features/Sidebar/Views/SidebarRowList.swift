import CodevisorUI
import SwiftUI

extension SidebarRowFold {
  fileprivate func shown(fold: CGFloat, base: CGFloat) -> CGFloat {
    let progress = min(1, max(0, fold - base))
    return switch self {
    case .kept: 1
    case .arriving: progress
    case .leaving: 1 - progress
    }
  }
}

struct SidebarRowList<Row: Equatable, ID: Hashable, Content: View>: View {
  let rows: [Row]
  let id: (Row) -> ID
  let animation: Animation?
  @ViewBuilder let content: (Row) -> Content
  @State private var shown: [Shown] = []
  @State private var isPrimed = false
  @State private var fold: CGFloat = 0
  @State private var base: CGFloat = 0
  @State private var batch = 0

  private struct Shown: Identifiable {
    let id: ID
    var row: Row
    var kind: SidebarRowFold
  }

  var body: some View {
    let displayed = isPrimed ? shown : rows.map { Shown(id: id($0), row: $0, kind: .kept) }
    SidebarRowStack(spacing: 1, fold: fold, base: base) {
      ForEach(displayed) { item in
        content(item.row)
          .modifier(
            SidebarRowFoldModifier(
              kind: item.kind, fold: item.kind == .leaving ? fold : 0, base: item.kind == .leaving ? base : 0)
          )
          .transition(item.kind == .arriving ? .opacity : .identity)
      }
    }
    .onAppear {
      shown = rows.map { Shown(id: id($0), row: $0, kind: .kept) }
      isPrimed = true
    }
    .onChange(of: rows) { previous, current in
      if previous.map(id) == current.map(id) { refresh() } else { reconcile() }
    }
  }

  private func refresh() {
    let current = Dictionary(rows.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    shown = shown.map { Shown(id: $0.id, row: current[$0.id] ?? $0.row, kind: $0.kind) }
  }

  private func reconcile() {
    settle()
    let previous = Dictionary(shown.map { ($0.id, $0.row) }, uniquingKeysWith: { first, _ in first })
    let current = Dictionary(rows.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    let steps = SidebarRowFold.plan(from: shown.map(\.id), to: rows.map(id))
    guard let animation, steps.contains(where: { $0.fold != .kept }) else {
      withAnimation(animation) { shown = rows.map { Shown(id: id($0), row: $0, kind: .kept) } }
      return
    }
    base = fold
    batch += 1
    let started = batch
    withAnimation(animation, completionCriteria: .logicallyComplete) {
      shown = steps.compactMap { step in
        (current[step.id] ?? previous[step.id]).map { Shown(id: step.id, row: $0, kind: step.fold) }
      }
      fold += 1
    } completion: {
      if batch == started { settle() }
    }
  }

  private func settle() {
    guard shown.contains(where: { $0.kind != .kept }) else { return }
    shown = shown.filter { $0.kind != .leaving }.map { Shown(id: $0.id, row: $0.row, kind: .kept) }
  }
}

nonisolated private struct SidebarRowFoldKey: LayoutValueKey {
  static let defaultValue = SidebarRowFold.kept
}

private struct SidebarRowFoldModifier: ViewModifier, Animatable {
  let kind: SidebarRowFold
  var fold: CGFloat
  let base: CGFloat

  var animatableData: CGFloat {
    get { fold }
    set { fold = newValue }
  }

  func body(content: Content) -> some View {
    SidebarRowClip { content }
      .clipped()
      .opacity(kind == .leaving ? kind.shown(fold: fold, base: base) : 1)
      .allowsHitTesting(kind != .leaving)
      .accessibilityHidden(kind == .leaving)
      .zIndex(kind == .kept ? 1 : 0)
      .layoutValue(key: SidebarRowFoldKey.self, value: kind)
  }
}

private struct SidebarRowStack: Layout {
  var spacing: CGFloat
  var fold: CGFloat
  let base: CGFloat

  var animatableData: CGFloat {
    get { fold }
    set { fold = newValue }
  }

  struct Cache {
    var width: CGFloat?
    var base: CGFloat = -1
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
    let isFolding = fold > base && fold < base + 1
    if isFolding, cache.base == base, cache.width == width, cache.sizes.count == subviews.count {
      return cache.sizes
    }
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    cache = Cache(width: width, base: base, sizes: sizes)
    return sizes
  }

  private func layout(
    _ subviews: Subviews, width: CGFloat?, cache: inout Cache
  ) -> (frames: [CGRect], height: CGFloat) {
    let sizes = sizes(of: subviews, width: width, cache: &cache)
    let kinds = subviews.map { $0[SidebarRowFoldKey.self] }
    var blocks: [Range<Int>] = []
    for index in kinds.indices {
      if let last = blocks.last, kinds[index] != .kept, kinds[last.lowerBound] == kinds[index] {
        blocks[blocks.count - 1] = last.lowerBound..<(index + 1)
      } else {
        blocks.append(index..<(index + 1))
      }
    }
    var frames = sizes.map { CGRect(origin: .zero, size: $0) }
    var y: CGFloat = 0
    var gapTaken = false
    for (number, block) in blocks.enumerated() {
      let kind = kinds[block.lowerBound]
      let hasPrevious = number > 0
      guard kind != .kept else {
        if hasPrevious && !gapTaken { y += spacing }
        frames[block.lowerBound].origin.y = y
        y += sizes[block.lowerBound].height
        gapTaken = false
        continue
      }
      let shown = kind.shown(fold: fold, base: base)
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
