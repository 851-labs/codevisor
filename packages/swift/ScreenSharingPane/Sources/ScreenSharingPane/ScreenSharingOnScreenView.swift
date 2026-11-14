#if os(iOS)
  import UIKit

  final class ScreenSharingOnScreenView: UIView {
    var onChange: ((Bool) -> Void)?
    private(set) var isOnScreen = false
    private var sceneIsActive = false
    private weak var watchedScene: UIScene?

    override init(frame: CGRect) {
      super.init(frame: frame)
      isUserInteractionEnabled = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      watch(window?.windowScene)
      report()
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      report()
    }

    func retire() {
      watch(nil)
      settle(false)
      onChange = nil
    }

    private func watch(_ scene: UIScene?) {
      let center = NotificationCenter.default
      center.removeObserver(self, name: UIScene.didActivateNotification, object: watchedScene)
      center.removeObserver(self, name: UIScene.willDeactivateNotification, object: watchedScene)
      watchedScene = scene
      sceneIsActive = scene?.activationState == .foregroundActive
      guard let scene else { return }

      center.addObserver(
        self, selector: #selector(sceneActivated), name: UIScene.didActivateNotification, object: scene)
      center.addObserver(
        self, selector: #selector(sceneDeactivating), name: UIScene.willDeactivateNotification, object: scene)
    }

    @objc private func sceneActivated() {
      sceneIsActive = true
      report()
    }

    @objc private func sceneDeactivating() {
      sceneIsActive = false
      report()
    }

    private func report() {
      settle(window != nil && sceneIsActive && !bounds.isEmpty)
    }

    private func settle(_ onScreen: Bool) {
      guard onScreen != isOnScreen else { return }

      isOnScreen = onScreen
      onChange?(onScreen)
    }
  }
#endif
