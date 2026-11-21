import CodevisorUI
import SwiftUI

struct SidebarHeaderGhost: View {
  let title: String
  var icon: SidebarGroupIcon?

  var body: some View {
    HStack(spacing: 7) {
      if let icon {
        icon.image
          .font(.system(size: SidebarRowIcon.size, weight: SidebarRowIcon.weight))
          .foregroundStyle(.secondary)
          .frame(width: 18)
      }
      Text(title)
        .lineLimit(1)
      Spacer(minLength: 0)
    }
    .padding(.horizontal, 10)
  }
}
