import SwiftUI

struct WorkspaceDeckLayout: Layout {
  func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
    proposal.replacingUnspecifiedDimensions()
  }

  func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
    let size = ProposedViewSize(bounds.size)
    for subview in subviews {
      subview.place(at: bounds.origin, anchor: .topLeading, proposal: size)
    }
  }
}
