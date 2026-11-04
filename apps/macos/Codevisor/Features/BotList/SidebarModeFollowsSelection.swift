import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarModeFollowsSelection: ViewModifier {
  @Binding var selection: SidebarSelection?
  let onNavigate: () -> Void
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode

  private var activeMode: SidebarMode { SidebarMode.active(storedMode, botsEnabled: botsEnabled) }

  func body(content: Content) -> some View {
    content
      .onChange(of: selection, initial: true) { _, next in
        onNavigate()
        followSelection(next)
      }
  }

  private func followSelection(_ next: SidebarSelection?) {
    guard botsEnabled, let owner = next?.owningMode, owner != activeMode else { return }
    storedMode = owner
  }
}
