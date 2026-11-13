import CodevisorUI
import SwiftUI

struct SidebarModeRow: View {
  static let height: CGFloat = 44
  private static let rowInset: CGFloat = 10
  private static let glassSpacing: CGFloat = 8

  @Binding var mode: SidebarMode
  let actions: RootSidebarActions?

  var body: some View {
    SidebarVibrancyHost {
      GlassEffectContainer(spacing: Self.glassSpacing) {
        HStack(spacing: Self.glassSpacing) {
          SidebarModeSwitch(mode: $mode)
          Spacer(minLength: 0)
          SidebarModeNewButton(mode: mode, newChat: { actions?.newChat() }, newBot: { actions?.newBot() })
            .buttonStyle(SidebarModeNewButtonStyle())
            .disabled(actions == nil)
        }
      }
      .padding(.horizontal, Self.rowInset)
    }
    .frame(height: Self.height)
  }
}
