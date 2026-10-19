import SwiftUI

struct ToolIconSlot<Icon: View>: View {
  @ViewBuilder let icon: () -> Icon

  @ScaledMetric(relativeTo: ToolIconMetrics.textStyle) private var side = ToolIconMetrics.side

  var body: some View {
    TextLineSlot(width: ToolIconMetrics.columnWidth) {
      icon()
        .frame(width: side, height: side)
        .environment(\.toolIconSide, side)
    }
  }
}
