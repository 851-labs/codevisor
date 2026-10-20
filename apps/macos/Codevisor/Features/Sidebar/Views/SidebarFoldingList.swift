import CodevisorUI
import Observation
import SwiftUI

@MainActor
@Observable
final class SidebarFoldState {
  private(set) var sections: [String: Int] = [:]
  @ObservationIgnored private var generation = 0

  func isFolding(_ section: String) -> Bool {
    sections[section] != nil
  }

  func begin(_ section: String) -> Int {
    generation += 1
    sections[section] = generation
    return generation
  }

  func end(_ section: String, generation: Int) {
    if sections[section] == generation { sections[section] = nil }
  }

  private(set) var released: [UUID: Int] = [:]

  func isReleasing(_ id: UUID) -> Bool {
    released[id] != nil
  }

  func release(_ id: UUID) -> Int {
    generation += 1
    released[id] = generation
    return generation
  }

  func endRelease(_ id: UUID, generation: Int) {
    if released[id] == generation { released[id] = nil }
  }

  private(set) var archiving: Set<UUID> = []

  func isArchiving(_ id: UUID) -> Bool {
    archiving.contains(id)
  }

  func beginArchive(_ id: UUID) -> Bool {
    archiving.insert(id).inserted
  }

  func endArchive(_ id: UUID) {
    archiving.remove(id)
  }

  @ObservationIgnored private var arriving: Set<UUID> = []

  func isArriving(_ id: UUID) -> Bool {
    arriving.contains(id)
  }

  func arrive(_ id: UUID) {
    arriving.insert(id)
  }

  func endArrival(_ id: UUID) {
    arriving.remove(id)
  }
}

struct SidebarStack: Layout {
  var spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let frames = layout(subviews, width: proposal.width)
    return CGSize(width: frames.map(\.maxX).max() ?? 0, height: frames.last?.maxY ?? 0)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (subview, frame) in zip(subviews, layout(subviews, width: bounds.width)) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: frame.height)
      )
    }
  }

  private func layout(_ subviews: Subviews, width: CGFloat?) -> [CGRect] {
    var frames: [CGRect] = []
    var y: CGFloat = 0
    var tallestAbove: CGFloat = 0
    for subview in subviews {
      let size = subview.sizeThatFits(ProposedViewSize(width: width, height: nil))
      y += min(spacing, size.height, tallestAbove)
      frames.append(CGRect(x: 0, y: y, width: size.width, height: size.height))
      y += size.height
      tallestAbove = max(tallestAbove, size.height)
    }
    return frames
  }
}

nonisolated struct SidebarFoldProgress: Equatable {
  var shown: CGFloat
  var released: CGFloat
}

nonisolated enum SidebarFoldKind: Equatable {
  case kept
  case folding
  case releasing
}

struct SidebarFoldingList<Content: View>: View {
  let shows: Bool
  let isReleasing: Bool
  let content: (SidebarFoldProgress) -> Content
  @Environment(\.accessibilityReduceMotion) private var reduceMotion
  @State private var shown: CGFloat
  @State private var released: CGFloat = 1

  init(
    shows: Bool, appearsFolded: Bool = false, isReleasing: Bool = false,
    @ViewBuilder content: @escaping (SidebarFoldProgress) -> Content
  ) {
    self.shows = shows
    self.isReleasing = isReleasing
    self.content = content
    _shown = State(initialValue: shows && !appearsFolded ? 1 : 0)
  }

  var body: some View {
    let progress = SidebarFoldProgress(shown: shown, released: released)
    SidebarFoldingStack(spacing: 1, progress: progress) { content(progress) }
      .clipped()
      .onAppear(perform: animate)
      .onChange(of: shows) { _, _ in animate() }
      .onChange(of: isReleasing) { _, isReleasing in
        if isReleasing {
          withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) { released = 0 }
        } else {
          released = 1
        }
      }
  }

  private func animate() {
    let target: CGFloat = shows ? 1 : 0
    guard shown != target else { return }
    withAnimation(Motion.listReflow(reduceMotion: reduceMotion)) { shown = target }
  }
}

extension View {
  func sidebarFoldingRow(_ isFolding: Bool, progress: SidebarFoldProgress, shows: Bool) -> some View {
    sidebarFoldingRow(isFolding ? .folding : .kept, progress: progress, shows: shows)
  }

  func sidebarFoldingRow(_ kind: SidebarFoldKind, progress: SidebarFoldProgress, shows: Bool) -> some View {
    let opacity: CGFloat =
      switch kind {
      case .kept: 1
      case .folding: progress.shown
      case .releasing: progress.released
      }
    let leaving = kind == .releasing || (kind == .folding && !shows)
    return SidebarRowClip { self }
      .clipped()
      .opacity(opacity)
      .allowsHitTesting(!leaving)
      .accessibilityHidden(leaving)
      .zIndex(kind == .kept ? 1 : 0)
      .layoutValue(key: SidebarFoldKindKey.self, value: kind)
  }
}

nonisolated private struct SidebarFoldKindKey: LayoutValueKey {
  static let defaultValue = SidebarFoldKind.kept
}

private struct SidebarFoldingStack: Layout {
  var spacing: CGFloat
  var progress: SidebarFoldProgress

  var animatableData: AnimatablePair<CGFloat, CGFloat> {
    get { AnimatablePair(progress.shown, progress.released) }
    set { progress = SidebarFoldProgress(shown: newValue.first, released: newValue.second) }
  }

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let layout = layout(subviews, width: proposal.width)
    return CGSize(width: layout.frames.map(\.maxX).max() ?? 0, height: layout.height)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    for (subview, frame) in zip(subviews, layout(subviews, width: bounds.width).frames) {
      subview.place(
        at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
        anchor: .topLeading,
        proposal: ProposedViewSize(width: bounds.width, height: frame.height)
      )
    }
  }

  private func layout(_ subviews: Subviews, width: CGFloat?) -> (frames: [CGRect], height: CGFloat) {
    let sizes = subviews.map { $0.sizeThatFits(ProposedViewSize(width: width, height: nil)) }
    let kinds = subviews.map { $0[SidebarFoldKindKey.self] }
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
      let shown = kind == .folding ? progress.shown : progress.released
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
