import CodevisorUI
import SwiftUI

struct ChildAgentsRowLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    let pillHeight = subviews.first?.sizeThatFits(.unspecified).height ?? 0
    return CGSize(width: proposal.replacingUnspecifiedDimensions().width, height: pillHeight)
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    guard let pill = subviews.first else { return }

    let pillSize = pill.sizeThatFits(.unspecified)
    pill.place(at: CGPoint(x: bounds.minX, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(pillSize))

    for accessory in subviews.dropFirst() {
      place(accessory, in: bounds, after: pillSize.width)
    }
  }

  private func place(_ accessory: LayoutSubview, in bounds: CGRect, after pillWidth: CGFloat) {
    let size = accessory.sizeThatFits(.unspecified)
    let centeredX = bounds.midX - size.width / 2
    let clearOfPillX = bounds.minX + pillWidth + ComposerGlassStyle.clusterSpacing
    let x = max(centeredX, clearOfPillX)
    accessory.place(at: CGPoint(x: x, y: bounds.midY), anchor: .leading, proposal: ProposedViewSize(size))
  }
}
