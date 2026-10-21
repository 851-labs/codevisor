import CodevisorUI
import SwiftUI

nonisolated private struct SidebarRowPhase: Equatable {
  var fold: SidebarRowFold
  var channel: Int

  static let kept = SidebarRowPhase(fold: .kept, channel: 0)
}

nonisolated private struct SidebarFoldChannels: Equatable {
  var progress = AnimatablePair<CGFloat, CGFloat>(0, 0)
  var bases: (CGFloat, CGFloat) = (0, 0)

  static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.progress == rhs.progress && lhs.bases == rhs.bases
  }

  func value(_ channel: Int) -> CGFloat { channel == 0 ? progress.first : progress.second }

  func base(_ channel: Int) -> CGFloat { channel == 0 ? bases.0 : bases.1 }

  var isFolding: Bool {
    (0...1).contains { value($0) > base($0) && value($0) < base($0) + 1 }
  }

  func shown(_ phase: SidebarRowPhase) -> CGFloat {
    let progress = min(1, max(0, value(phase.channel) - base(phase.channel)))
    return switch phase.fold {
    case .kept: 1
    case .arriving: progress
    case .leaving: 1 - progress
    }
  }

  mutating func begin(_ channel: Int) {
    if channel == 0 { bases.0 = progress.first } else { bases.1 = progress.second }
  }

  mutating func advance(_ channel: Int) {
    if channel == 0 { progress.first += 1 } else { progress.second += 1 }
  }
}

struct SidebarRowList<Row: Equatable, ID: Hashable, Content: View>: View {
  let rows: [Row]
  let id: (Row) -> ID
  let animation: Animation?
  @ViewBuilder let content: (Row) -> Content
  @State private var shown: [Shown] = []
  @State private var isPrimed = false
  @State private var channels = SidebarFoldChannels()
  @State private var batch = 0

  private struct Shown: Identifiable {
    let id: ID
    var row: Row
    var phase: SidebarRowPhase
  }

  var body: some View {
    let displayed = isPrimed ? shown : rows.map { Shown(id: id($0), row: $0, phase: .kept) }
    SidebarRowStack(spacing: 1, channels: channels) {
      ForEach(displayed) { item in
        content(item.row)
          .modifier(
            SidebarRowFoldModifier(
              phase: item.phase, channels: item.phase.fold == .leaving ? channels : SidebarFoldChannels())
          )
          .transition(item.phase.fold == .arriving ? .opacity : .identity)
      }
    }
    .onAppear {
      shown = rows.map { Shown(id: id($0), row: $0, phase: .kept) }
      isPrimed = true
    }
    .onChange(of: rows) { previous, current in
      if previous.map(id) == current.map(id) { refresh() } else { reconcile() }
    }
  }

  private func refresh() {
    let current = Dictionary(rows.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    shown = shown.map { Shown(id: $0.id, row: current[$0.id] ?? $0.row, phase: $0.phase) }
  }

  private func reconcile() {
    guard let animation else {
      shown = rows.map { Shown(id: id($0), row: $0, phase: .kept) }
      return
    }
    let existing = Dictionary(shown.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    let current = Dictionary(rows.map { (id($0), $0) }, uniquingKeysWith: { first, _ in first })
    let present = shown.filter { $0.phase.fold != .leaving }
    let steps = SidebarRowFold.plan(from: present.map(\.id), to: rows.map(id))
    let folds = steps.contains { $0.fold != .kept }
    let channel = (batch + 1) % 2
    var entries: [Shown] = steps.compactMap { step in
      guard let row = current[step.id] ?? existing[step.id]?.row else { return nil }
      if step.fold == .kept, let phase = existing[step.id]?.phase, phase.fold == .arriving, phase.channel != channel {
        return Shown(id: step.id, row: row, phase: phase)
      }
      let phase = step.fold == .kept ? SidebarRowPhase.kept : SidebarRowPhase(fold: step.fold, channel: channel)
      return Shown(id: step.id, row: row, phase: phase)
    }
    entries = Self.keepingInFlight(shown, in: entries, freeing: folds ? channel : nil)
    guard folds else {
      withAnimation(animation) { shown = entries }
      return
    }
    batch += 1
    let started = batch
    channels.begin(channel)
    withAnimation(animation, completionCriteria: .logicallyComplete) {
      shown = entries
      channels.advance(channel)
    } completion: {
      if batch == started { settle() }
    }
  }

  private static func keepingInFlight(_ shown: [Shown], in entries: [Shown], freeing channel: Int?) -> [Shown] {
    let entryIDs = Set(entries.map(\.id))
    let inFlight = shown.filter {
      !entryIDs.contains($0.id) && $0.phase.fold == .leaving && $0.phase.channel != channel
    }
    return SidebarRowFold.interleave(inFlight, into: entries, by: shown.map(\.id), id: \.id)
  }

  private func settle() {
    guard shown.contains(where: { $0.phase.fold != .kept }) else { return }
    shown = shown.filter { $0.phase.fold != .leaving }.map { Shown(id: $0.id, row: $0.row, phase: .kept) }
  }
}

nonisolated private struct SidebarRowPhaseKey: LayoutValueKey {
  static let defaultValue = SidebarRowPhase.kept
}

private struct SidebarRowFoldModifier: ViewModifier, Animatable {
  let phase: SidebarRowPhase
  var channels: SidebarFoldChannels

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { channels.progress }
    set { channels.progress = newValue }
  }

  func body(content: Content) -> some View {
    SidebarRowClip { content }
      .clipped()
      .opacity(phase.fold == .leaving ? channels.shown(phase) : 1)
      .allowsHitTesting(phase.fold != .leaving)
      .accessibilityHidden(phase.fold == .leaving)
      .zIndex(phase.fold == .kept ? 1 : 0)
      .layoutValue(key: SidebarRowPhaseKey.self, value: phase)
  }
}

private struct SidebarRowStack: Layout {
  var spacing: CGFloat
  var channels: SidebarFoldChannels

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { channels.progress }
    set { channels.progress = newValue }
  }

  struct Cache {
    var width: CGFloat?
    var bases: [CGFloat] = []
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
    let bases = [channels.base(0), channels.base(1)]
    if channels.isFolding, cache.bases == bases, cache.width == width, cache.sizes.count == subviews.count {
      return cache.sizes
    }
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    cache = Cache(width: width, bases: bases, sizes: sizes)
    return sizes
  }

  private func layout(
    _ subviews: Subviews, width: CGFloat?, cache: inout Cache
  ) -> (frames: [CGRect], height: CGFloat) {
    let sizes = sizes(of: subviews, width: width, cache: &cache)
    let phases = subviews.map { $0[SidebarRowPhaseKey.self] }
    var blocks: [Range<Int>] = []
    for index in phases.indices {
      if let last = blocks.last, phases[index].fold != .kept, phases[last.lowerBound] == phases[index] {
        blocks[blocks.count - 1] = last.lowerBound..<(index + 1)
      } else {
        blocks.append(index..<(index + 1))
      }
    }
    var frames = sizes.map { CGRect(origin: .zero, size: $0) }
    var y: CGFloat = 0
    var gapTaken = false
    for (number, block) in blocks.enumerated() {
      let phase = phases[block.lowerBound]
      let hasPrevious = number > 0
      guard phase.fold != .kept else {
        if hasPrevious && !gapTaken { y += spacing }
        frames[block.lowerBound].origin.y = y
        y += sizes[block.lowerBound].height
        gapTaken = false
        continue
      }
      let shown = channels.shown(phase)
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
