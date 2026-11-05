import SwiftUI

struct WorkspaceVisibility: ViewModifier {
  let onShow: () -> Void
  let onHide: () -> Void
  @Environment(WorkspaceActivity.self) private var activity: WorkspaceActivity?
  @State private var isAppeared = false
  @State private var isShown = false

  func body(content: Content) -> some View {
    content
      .onAppear { update(appeared: true, active: isWorkspaceActive) }
      .onDisappear { update(appeared: false, active: isWorkspaceActive) }
      .onChange(of: isWorkspaceActive) { _, active in update(appeared: isAppeared, active: active) }
  }

  private var isWorkspaceActive: Bool { activity?.isActive ?? true }

  private func update(appeared: Bool, active: Bool) {
    isAppeared = appeared
    let shown = appeared && active
    guard shown != isShown else { return }

    isShown = shown
    if shown {
      onShow()
    } else {
      onHide()
    }
  }
}

extension View {
  func onWorkspaceVisibilityChange(show: @escaping () -> Void, hide: @escaping () -> Void) -> some View {
    modifier(WorkspaceVisibility(onShow: show, onHide: hide))
  }
}
