#if os(iOS)
  import UIKit

  final class ScreenSharingOnScreenView: UIView {
    var onChange: ((Bool) -> Void)?
    private var state = ScreenSharingOnScreenState()
    private weak var watchedScene: UIScene?

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    var isOnScreen: Bool { state.isOnScreen }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      let scene = window?.windowScene
      watch(scene)
      update {
        $0.isInWindow = self.window != nil
        $0.sceneIsActive = scene?.activationState == .foregroundActive
      }
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      update { $0.hasSize = !self.bounds.isEmpty }
    }

    func retire() {
      watch(nil)
      update { $0 = ScreenSharingOnScreenState() }
      onChange = nil
    }

    private func watch(_ scene: UIScene?) {
      let center = NotificationCenter.default
      center.removeObserver(self, name: UIScene.didActivateNotification, object: watchedScene)
      center.removeObserver(self, name: UIScene.willDeactivateNotification, object: watchedScene)
      watchedScene = scene
      guard let scene else { return }

      center.addObserver(
        self, selector: #selector(sceneActivated), name: UIScene.didActivateNotification, object: scene)
      center.addObserver(
        self, selector: #selector(sceneDeactivating), name: UIScene.willDeactivateNotification, object: scene)
    }

    @objc private func sceneActivated() {
      update { $0.sceneIsActive = true }
    }

    @objc private func sceneDeactivating() {
      update { $0.sceneIsActive = false }
    }

    private func update(_ change: (inout ScreenSharingOnScreenState) -> Void) {
      guard let onScreen = state.change(change) else { return }

      onChange?(onScreen)
    }
  }
#endif
