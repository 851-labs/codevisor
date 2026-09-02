import SwiftUI
import UIKit

/// Measures one SwiftUI row at a fixed document width. The controller belongs
/// to `TranscriptViewController`, never to the surrounding navigation screen.
@MainActor
final class TranscriptContentHostingController: UIHostingController<AnyView> {
    var onLaidOutHeightChange: ((CGFloat) -> Void)?

    private var lastReportedHeight: CGFloat = 0
    private var measurementGeneration: UInt64 = 0
    private var pendingMeasurementTask: Task<Void, Never>?

    override init(rootView: AnyView) {
        super.init(rootView: rootView)
        sizingOptions = [.intrinsicContentSize]
        // A transcript row lives in document coordinates. Its size must not
        // depend on whether it currently intersects screen chrome.
        safeAreaRegions = []
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        pendingMeasurementTask?.cancel()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        scheduleMeasurement()
    }

    func installRootView(_ rootView: AnyView) {
        measurementGeneration &+= 1
        pendingMeasurementTask?.cancel()
        pendingMeasurementTask = nil
        lastReportedHeight = 0
        self.rootView = rootView
        invalidateContentSize()
    }

    func invalidateContentSize(forceReport: Bool = false) {
        if forceReport { lastReportedHeight = 0 }
        view.invalidateIntrinsicContentSize()
        view.setNeedsLayout()
        view.superview?.setNeedsLayout()
        scheduleMeasurement()
    }

    func resetReportedHeight() {
        lastReportedHeight = 0
    }

    private func scheduleMeasurement() {
        guard pendingMeasurementTask == nil else { return }
        let generation = measurementGeneration
        pendingMeasurementTask = Task { @MainActor [weak self] in
            // Root replacement and observed SwiftUI updates reconcile after
            // UIKit's current layout callback. Two yields keep an old root's
            // fitting size from becoming authoritative for the new revision.
            await Task.yield()
            await Task.yield()
            guard let self, !Task.isCancelled,
                measurementGeneration == generation
            else { return }
            pendingMeasurementTask = nil
            view.layoutIfNeeded()
            measureAndReportHeight()
        }
    }

    private func measureAndReportHeight() {
        let width = view.bounds.width
        guard width > 1 else { return }
        let measured = sizeThatFits(
            in: CGSize(width: width, height: .greatestFiniteMagnitude),
        ).height
        guard measured.isFinite, measured > 0 else { return }
        let scale = TranscriptPixelGeometry.displayScale(for: view)
        let height = max(1, TranscriptPixelGeometry.ceil(measured, scale: scale))
        guard TranscriptPixelGeometry.differs(lastReportedHeight, height, scale: scale) else {
            return
        }
        lastReportedHeight = height
        onLaidOutHeightChange?(height)
    }
}
