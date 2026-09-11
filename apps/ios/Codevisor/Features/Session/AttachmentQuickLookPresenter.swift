import QuickLook
import SwiftUI

extension View {
  func attachmentQuickLookPreview(_ url: Binding<URL?>) -> some View {
    background(AttachmentQuickLookPresenter(selection: url))
  }
}

/// Keep Quick Look's chrome and interactive dismissal in one UIKit presentation.
/// Both dismissal paths clear the selection so the same link can open again.
private struct AttachmentQuickLookPresenter: UIViewControllerRepresentable {
  @Binding var selection: URL?

  func makeUIViewController(context: Context) -> Presenter {
    Presenter(selection: $selection)
  }

  func updateUIViewController(_ controller: Presenter, context: Context) {
    controller.selection = $selection
    controller.updatePresentation()
  }

  static func dismantleUIViewController(_ controller: Presenter, coordinator: ()) {
    controller.preview?.dismiss(animated: false)
  }

  final class Presenter: UIViewController, QLPreviewControllerDelegate,
    UIAdaptivePresentationControllerDelegate
  {
    var selection: Binding<URL?>
    var preview: UINavigationController?
    private var source: PreviewSource?

    init(selection: Binding<URL?>) {
      self.selection = selection
      super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { nil }

    override func loadView() {
      view = UIView()
      view.isUserInteractionEnabled = false
    }

    override func viewDidAppear(_ animated: Bool) {
      super.viewDidAppear(animated)
      updatePresentation()
    }

    func updatePresentation() {
      guard let url = selection.wrappedValue else {
        if let preview, !preview.isBeingDismissed {
          preview.dismiss(animated: true) { [weak self, weak preview] in
            guard let preview else { return }
            self?.didDismiss(preview)
          }
        }
        return
      }
      guard preview == nil, viewIfLoaded?.window != nil else { return }
      let source = PreviewSource(url: url)
      let controller = QLPreviewController()
      controller.dataSource = source
      controller.delegate = self
      let navigation = UINavigationController(rootViewController: controller)
      navigation.modalPresentationStyle = .pageSheet
      navigation.sheetPresentationController?.detents = [.large()]
      navigation.sheetPresentationController?.prefersGrabberVisible = true
      navigation.presentationController?.delegate = self
      controller.navigationItem.leftBarButtonItem = UIBarButtonItem(
        systemItem: .close,
        primaryAction: UIAction { [weak self, weak navigation] _ in
          navigation?.dismiss(animated: true) {
            guard let navigation else { return }
            self?.didDismiss(navigation)
          }
        }
      )
      self.source = source
      preview = navigation
      present(navigation, animated: true)
    }

    func previewControllerDidDismiss(_ controller: QLPreviewController) {
      guard let preview, preview.viewControllers.contains(controller) else { return }
      didDismiss(preview)
    }

    private func didDismiss(_ controller: UINavigationController) {
      guard preview === controller else { return }
      if selection.wrappedValue == source?.url {
        selection.wrappedValue = nil
      }
      preview = nil
      source = nil
    }

    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
      guard let preview else { return }
      didDismiss(preview)
    }
  }

  final class PreviewSource: NSObject, QLPreviewControllerDataSource {
    let url: URL

    init(url: URL) { self.url = url }

    nonisolated func numberOfPreviewItems(in controller: QLPreviewController) -> Int { 1 }

    nonisolated func previewController(
      _ controller: QLPreviewController, previewItemAt index: Int
    ) -> QLPreviewItem {
      url as NSURL
    }
  }
}
