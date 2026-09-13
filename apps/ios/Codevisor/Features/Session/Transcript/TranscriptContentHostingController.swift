import CodevisorUI
import SwiftUI
import UIKit

/// Reports the placed SwiftUI row at its document width. The controller
/// belongs to `TranscriptViewController`, never the navigation screen.
@MainActor
final class TranscriptContentHostingController: UIHostingController<AnyView> {
  var onLaidOutHeightChange: ((CGFloat) -> Void)?
  private let layoutObserver = TranscriptContentLayoutObserver()
  private var lastReportedHeight: CGFloat = 0
  private var pendingLayoutSize: CGSize?

  override init(rootView: AnyView) {
    super.init(rootView: AnyView(EmptyView()))
    sizingOptions = [.intrinsicContentSize]
    // A transcript row lives in document coordinates. Its size must not
    // depend on whether it currently intersects screen chrome.
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
    // SwiftUI can place the row at its document width before Auto Layout
    // applies that width to the hosting view. Its geometry will not change
    // again when UIKit catches up, so preserve the report until then.
    pendingLayoutSize = size
    reportPendingLayout()
  }

  private func reportPendingLayout() {
    guard let size = pendingLayoutSize else { return }
    guard abs(size.width - view.bounds.width) <= 0.5 else { return }
    pendingLayoutSize = nil
    let scale = TranscriptPixelGeometry.displayScale(for: view)
    // Empty rows also complete presentation; match the ledger's 1pt floor.
    let height = max(1, TranscriptPixelGeometry.ceil(size.height, scale: scale))
    guard TranscriptPixelGeometry.differs(lastReportedHeight, height, scale: scale) else { return }
    lastReportedHeight = height
    onLaidOutHeightChange?(height)
  }
}
