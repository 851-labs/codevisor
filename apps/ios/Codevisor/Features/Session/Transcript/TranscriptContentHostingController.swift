import CodevisorUI
import SwiftUI
import UIKit

@MainActor
final class TranscriptContentHostingController: UIHostingController<AnyView> {
  var onLaidOutHeightChange: ((CGFloat) -> Void)?
  private let layoutObserver = TranscriptContentLayoutObserver()
  private var lastReportedHeight: CGFloat = 0
  private var pendingLayoutSize: CGSize?

  override init(rootView: AnyView) {
    super.init(rootView: AnyView(EmptyView()))
    sizingOptions = [.intrinsicContentSize]
    safeAreaRegions = []
    layoutObserver.onLayout = { [weak self] size in
      self?.reportLayout(size)
    }
    installRootView(rootView)
  }

  @available(*, unavailable)
  required init?(coder _: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  func installRootView(_ content: AnyView) {
    lastReportedHeight = 0
    rootView = layoutObserver.install(content)
    invalidateContentSize()
  }

  func invalidateContentSize(forceReport: Bool = false) {
    if forceReport { lastReportedHeight = 0 }
    pendingLayoutSize = nil
    layoutObserver.invalidate()
    view.invalidateIntrinsicContentSize()
    view.setNeedsLayout()
    view.superview?.setNeedsLayout()
  }

  func resetReportedHeight() {
    lastReportedHeight = 0
    pendingLayoutSize = nil
    layoutObserver.invalidate()
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    reportPendingLayout()
  }

  private func reportLayout(_ size: CGSize) {
    pendingLayoutSize = size
    reportPendingLayout()
  }

  private func reportPendingLayout() {
    guard let size = pendingLayoutSize else { return }
    guard abs(size.width - view.bounds.width) <= 0.5 else { return }
    pendingLayoutSize = nil
    let scale = TranscriptPixelGeometry.displayScale(for: view)
    let height = max(1, TranscriptPixelGeometry.ceil(size.height, scale: scale))
    guard TranscriptPixelGeometry.differs(lastReportedHeight, height, scale: scale) else { return }
    lastReportedHeight = height
    onLaidOutHeightChange?(height)
  }
}
