import CodevisorUI
import SwiftUI

struct SidebarModeSwitch: View {
  private static let capsuleInsets = EdgeInsets(top: 4, leading: 6, bottom: 4, trailing: 6)

  @Binding var mode: SidebarMode

  var body: some View {
    SidebarModeSegments(mode: $mode)
      .controlSize(.large)
      .padding(Self.capsuleInsets)
      .glassEffect(.regular, in: .capsule)
  }
}
