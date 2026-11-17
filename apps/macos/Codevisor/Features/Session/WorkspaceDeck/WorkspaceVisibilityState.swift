import Foundation

final class WorkspaceVisibilityState {
  let id = UUID()
  private var isAppeared = false
  private var isShown = false
  private var onShow: () -> Void = {}
  private var onHide: () -> Void = {}

  func handle(show: @escaping () -> Void, hide: @escaping () -> Void) {
    onShow = show
    onHide = hide
  }

  func update(active: Bool) {
    update(appeared: isAppeared, active: active)
  }

  func update(appeared: Bool, active: Bool) {
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
