import SwiftUI

struct BotMascotSwatchRows: Layout {
  let spacing: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    grid(for: subviews, width: proposal.width).size(filling: proposal.width)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let grid = grid(for: subviews, width: bounds.width)
    for (index, subview) in subviews.enumerated() {
      subview.place(at: grid.origin(of: index, in: bounds), proposal: ProposedViewSize(grid.cell))
    }
  }

  private func grid(for subviews: Subviews, width: CGFloat?) -> BotMascotSwatchGrid {
    BotMascotSwatchGrid(count: subviews.count, cell: largestCell(of: subviews), spacing: spacing, width: width)
  }

  private func largestCell(of subviews: Subviews) -> CGSize {
    subviews.map { $0.sizeThatFits(.unspecified) }.reduce(.zero) {
      CGSize(width: max($0.width, $1.width), height: max($0.height, $1.height))
    }
  }
}
