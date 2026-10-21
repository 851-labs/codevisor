#if canImport(AppKit)
  import AppKit
  import SwiftUI

  struct HeightLimitedScrollView<Content: View>: NSViewRepresentable {
    let maxHeight: CGFloat
    let content: Content

    func makeNSView(context: Context) -> HeightLimitedScrollContainer {
      HeightLimitedScrollContainer()
    }

    func updateNSView(_ container: HeightLimitedScrollContainer, context: Context) {
      container.maxHeight = maxHeight
      container.setContent(content.environment(\.self, context.environment))
    }

    func sizeThatFits(
      _ proposal: ProposedViewSize, nsView container: HeightLimitedScrollContainer, context: Context
    ) -> CGSize? {
      container.fit(toWidth: proposal.width.flatMap { $0.isFinite ? $0 : nil })
    }
  }
#endif
