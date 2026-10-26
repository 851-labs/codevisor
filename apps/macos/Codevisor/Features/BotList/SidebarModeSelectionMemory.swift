import CodevisorCore
import SwiftUI

struct SidebarModeSelectionMemory: ViewModifier {
  @Binding var selection: SidebarSelection?
  @ClientPreference(FeatureFlag.bots.preferenceKey, default: false) private var botsEnabled
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @State private var remembered: [SidebarMode: SidebarSelection] = [:]

  private var activeMode: SidebarMode { SidebarMode.active(storedMode, botsEnabled: botsEnabled) }

  func body(content: Content) -> some View {
    content
      .onChange(of: activeMode) { _, next in restoreSelection(for: next) }
      .onChange(of: selection, initial: true) { _, next in followSelection(next) }
  }

  private func restoreSelection(for mode: SidebarMode) {
    guard selection.flatMap(SidebarMode.owning) != mode else { return }

    selection = remembered[mode] ?? mode.defaultSelection
  }

  private func followSelection(_ next: SidebarSelection?) {
    guard let next else { return }

    let owner = SidebarMode.owning(next) ?? activeMode
    remembered[owner] = next
    guard botsEnabled, owner != activeMode else { return }
    storedMode = owner
  }
}
