import SwiftUI

struct HomeSidebarListLabelStyle: LabelStyle {
  func makeBody(configuration: Configuration) -> some View {
    HomeSidebarListLabel(icon: configuration.icon, title: configuration.title)
  }
}

private struct HomeSidebarListLabel<Icon: View, Title: View>: View {
  let icon: Icon
  let title: Title

  @ScaledMetric(relativeTo: .body) private var iconWidth: CGFloat = 23.5
  @ScaledMetric(relativeTo: .body) private var spacing: CGFloat = 16.2

  var body: some View {
    HStack(spacing: spacing) {
      icon
        .imageScale(.large)
        .frame(width: iconWidth)
      title
        .fontWeight(.regular)
    }
  }
}
