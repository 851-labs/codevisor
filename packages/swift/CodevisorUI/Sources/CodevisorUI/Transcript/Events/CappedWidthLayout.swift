import SwiftUI

struct CappedWidthLayout: Layout {
  let maxWidth: CGFloat

  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    guard let content = subviews.first else { return .zero }
    return content.sizeThatFits(capped(proposal))
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    subviews.first?.place(at: bounds.origin, proposal: ProposedViewSize(bounds.size))
  }

  private func capped(_ proposal: ProposedViewSize) -> ProposedViewSize {
    ProposedViewSize(width: min(proposal.width ?? maxWidth, maxWidth), height: proposal.height)
  }
}
