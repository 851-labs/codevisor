import StreamMarkdown
import UIKit

/// SwiftUI owns this lightweight controller. The cached transcript remains a
/// child of exactly one container, keeping row controllers out of navigation.
@MainActor
final class TranscriptContainerViewController: UIViewController {
  private(set) var surface: TranscriptPresentationSurface?

  override func loadView() {
    view = UIView()
    view.backgroundColor = .clear
  }

  func attach(_ surface: TranscriptPresentationSurface) -> TranscriptViewController {
    let controller = surface.ensureController()
    if self.surface === surface, controller.parent === self { return controller }
    releaseSurface()
    (controller.parent as? TranscriptContainerViewController)?.releaseSurface()
    loadViewIfNeeded()
    self.surface = surface
    // Baseline before configure observes the restored projection. SwiftUI's
    // outer appearance callback can arrive afterward; resetting there would
    // swallow the first new chunk on a retained controller.
    surface.textAnimationRegistry.prepareForPresentation()
    controller.prepareForPresentationAttachment()
    addChild(controller)
    controller.view.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(controller.view)
    NSLayoutConstraint.activate([
      controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      controller.view.topAnchor.constraint(equalTo: view.topAnchor),
      controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
    ])
    controller.didMove(toParent: self)
    return controller
  }

  func releaseSurface() {
    guard let surface else { return }
    self.surface = nil
    let controller = surface.ensureController()
    guard controller.parent === self else { return }
    controller.suspendPresentation()
    controller.willMove(toParent: nil)
    controller.view.removeFromSuperview()
    controller.removeFromParent()
    TranscriptPresentationSurfaceCache.shared.scheduleTrim()
  }
}
