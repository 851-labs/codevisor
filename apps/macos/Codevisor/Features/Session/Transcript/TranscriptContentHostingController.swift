import AppKit
import CodevisorUI
import SwiftUI

final class TranscriptContentHostingController: NSHostingController<AnyView> {
  var onLaidOutHeightChange: ((CGFloat) -> Void)?
  var onLayoutCompleted: (() -> Void)?
  private let layoutObserver = TranscriptContentLayoutObserver()
  private var lastReportedHeight: CGFloat = 0

  override init(rootView: AnyView) {
    super.init(rootView: AnyView(EmptyView()))
    layoutObserver.onLayout = { [weak self] size in
      self?.reportLayout(size)
    }
    installRootView(rootView)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLayout() {
    super.viewDidLayout()
    onLayoutCompleted?()
  }

  func installRootView(_ content: AnyView) {
    rootView = layoutObserver.install(content)
  }

  private func reportLayout(_ size: CGSize) {
    guard abs(size.width - view.bounds.width) <= 0.5 else { return }
    let height = max(1, size.height.rounded(.up))
    guard abs(lastReportedHeight - height) > 0.5 else { return }
    lastReportedHeight = height
    onLaidOutHeightChange?(height)
  }

  func invalidateContentSize(forceReport: Bool = false) {
    if forceReport { lastReportedHeight = 0 }
    layoutObserver.invalidate()
    view.invalidateIntrinsicContentSize()
    view.needsLayout = true
    view.superview?.needsLayout = true
  }

  func resetReportedHeight() {
    lastReportedHeight = 0
    layoutObserver.invalidate()
  }

  /// Reuse the cached frame without a second sizing pass. The first placed
  /// layout still verifies that height, and subsequent geometry changes
  /// always report even when they occur inside an unchanged SwiftUI root.
  func useKnownContentHeight(_ height: CGFloat) {
    lastReportedHeight = height
  }
}
