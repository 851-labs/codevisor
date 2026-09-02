import AppKit
import SwiftUI

final class TranscriptContentHostingController: NSHostingController<AnyView> {
  var onLaidOutHeightChange: ((CGFloat) -> Void)?
  var onLayoutCompleted: (() -> Void)?
  private var lastReportedHeight: CGFloat = 0
  private var pendingMeasurementTask: Task<Void, Never>?
  private var usesKnownContentHeight = false
  private var needsHeightMeasurement = true
  private var lastMeasuredWidth: CGFloat = 0

  override func viewDidLayout() {
    super.viewDidLayout()
    measureAndReportHeightIfNeeded()
    onLayoutCompleted?()
  }

  deinit {
    pendingMeasurementTask?.cancel()
  }

  private func measureAndReportHeightIfNeeded() {
    guard !usesKnownContentHeight else { return }
    // Never measure against the placeholder width. A row's content width
    // starts at 1pt (see `TranscriptRowHost.contentWidthConstraint`) and
    // only becomes real once the host has been positioned and laid out; a
    // TextKit pass at 1pt wraps a message to one line fragment PER
    // CHARACTER, which is pure waste — the result is meaningless and is
    // always superseded. Skipping is safe: `TranscriptRowHost.layout()`
    // re-invalidates whenever the width actually changes, so the real
    // measurement still arrives.
    let width = view.bounds.width
    guard width > 1 else { return }
    guard needsHeightMeasurement || abs(lastMeasuredWidth - width) > 0.5 else { return }
    let proposedSize = CGSize(
      width: width,
      height: .greatestFiniteMagnitude
    )
    let measuredHeight = sizeThatFits(in: proposedSize).height
    needsHeightMeasurement = false
    lastMeasuredWidth = width
    let height = max(1, measuredHeight.rounded(.up))
    guard abs(lastReportedHeight - height) > 0.5 else { return }
    lastReportedHeight = height
    onLaidOutHeightChange?(height)
  }

  func invalidateContentSize(forceReport: Bool = false) {
    usesKnownContentHeight = false
    needsHeightMeasurement = true
    if forceReport {
      lastReportedHeight = 0
    }
    view.invalidateIntrinsicContentSize()
    view.needsLayout = true
    view.superview?.needsLayout = true
    // SwiftUI observation can update content entirely inside this hosting
    // controller without causing AppKit to lay the explicitly-sized outer
    // wrapper out again. Measure after SwiftUI commits that update so the
    // virtualizer never keeps positioning later rows from a stale height.
    guard pendingMeasurementTask == nil else { return }
    pendingMeasurementTask = Task { @MainActor [weak self] in
      await Task.yield()
      guard let self, !Task.isCancelled else { return }
      self.pendingMeasurementTask = nil
      self.view.layoutSubtreeIfNeeded()
      self.measureAndReportHeightIfNeeded()
    }
  }

  func resetReportedHeight() {
    usesKnownContentHeight = false
    needsHeightMeasurement = true
    lastMeasuredWidth = 0
    lastReportedHeight = 0
  }

  /// Accepts a revision- and width-checked height from the transcript cache.
  /// SwiftUI still lays the content out for display, but the outer hosting
  /// controller no longer asks the complete subtree to determine the same
  /// intrinsic height a second time during that layout pass.
  func useKnownContentHeight(_ height: CGFloat) {
    pendingMeasurementTask?.cancel()
    pendingMeasurementTask = nil
    lastReportedHeight = height
    usesKnownContentHeight = true
    needsHeightMeasurement = false
    lastMeasuredWidth = view.bounds.width
  }
}
