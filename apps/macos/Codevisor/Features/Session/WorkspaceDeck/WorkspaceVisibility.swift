import CodevisorUI
import SwiftUI

struct WorkspaceVisibility: ViewModifier {
  let onShow: () -> Void
  let onHide: () -> Void
  @Environment(WorkspaceActivity.self) private var activity: WorkspaceActivity?
  @State private var state = WorkspaceVisibilityState()

  func body(content: Content) -> some View {
    let _ = state.handle(show: onShow, hide: onHide)
    content
      .onAppear {
        activity?.addListener(state.id) { [state] active in state.update(active: active) }
        state.update(appeared: true, active: isWorkspaceActive)
      }
      .onDisappear {
        activity?.removeListener(state.id)
        state.update(appeared: false, active: isWorkspaceActive)
      }
      .onChange(of: isWorkspaceActive) { _, active in state.update(active: active) }
  }

  private var isWorkspaceActive: Bool { activity?.isActive ?? true }
}

extension View {
  func onWorkspaceVisibilityChange(show: @escaping () -> Void, hide: @escaping () -> Void) -> some View {
    modifier(WorkspaceVisibility(onShow: show, onHide: hide))
  }
}
