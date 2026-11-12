import CodevisorCore
import CodevisorUI
import SwiftUI

struct SidebarModeSelectionMemory: ViewModifier {
  @Binding var selection: SidebarSelection?
  let onNavigate: () -> Void
  @Environment(AppEnvironment.self) private var environment
  @ClientPreference(SidebarMode.preferenceKey, default: SidebarMode.code) private var storedMode
  @ClientPreference(RememberedSidebarSelection.preferenceKey, default: RememberedSidebarSelections())
  private var saved
  @State private var remembered = RememberedSidebarSelections()
  @State private var pendingMode: SidebarMode?
  @State private var isRestoring = false

  private var route: SidebarRoute<SidebarSelection> { SidebarRoute(mode: storedMode, selection: selection) }

  private var plan: SidebarRestorePlan { SidebarRestorePlan(environment: environment) }

  private var pendingRestore: SidebarRestore<SidebarSelection>? {
    pendingMode.map { plan.restore(remembered[$0], in: $0) }
  }

  func body(content: Content) -> some View {
    content
      .onChange(of: route, initial: true) { old, new in follow(from: old, to: new) }
      .onChange(of: pendingRestore) { _, restore in
        if let restore { apply(restore) }
      }
  }

  private func follow(from old: SidebarRoute<SidebarSelection>, to new: SidebarRoute<SidebarSelection>) {
    let isLaunch = old == new
    if isLaunch { remembered = saved }
    if isLaunch || new.selection != old.selection { selectionDidChange(to: new.selection) }

    let change = SidebarRouteChange(from: old, to: new, owner: \.owningMode)
    if let mode = change.remembers, let selection = new.selection { remember(selection, in: mode) }
    if let mode = change.restores { restore(mode) }
  }

  private func selectionDidChange(to next: SidebarSelection?) {
    if isRestoring {
      isRestoring = false
    } else {
      pendingMode = nil
      onNavigate()
    }
    switchMode(toOwnerOf: next)
  }

  private func switchMode(toOwnerOf next: SidebarSelection?) {
    guard let owner = next?.owningMode, owner != storedMode else { return }

    storedMode = owner
  }

  private func remember(_ selection: SidebarSelection, in mode: SidebarMode) {
    let entry = plan.remembering(selection)
    guard remembered[mode] != entry else { return }

    remembered[mode] = entry
    saved[mode] = entry
  }

  private func restore(_ mode: SidebarMode) {
    pendingMode = nil
    guard selection?.owningMode != mode else { return }

    let restore = plan.restore(remembered[mode], in: mode)
    if restore == .wait { pendingMode = mode }
    apply(restore)
  }

  private func apply(_ restore: SidebarRestore<SidebarSelection>) {
    guard case let .select(target) = restore else { return }

    pendingMode = nil
    guard target != selection else { return }

    isRestoring = true
    selection = target
  }
}
