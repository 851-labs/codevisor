import AppKit
import SwiftUI

final class TranscriptContentHostingController: NSHostingController<AnyView> {
    var onLaidOutHeightChange: ((CGFloat) -> Void)?
    private var lastReportedHeight: CGFloat = 0
    private var pendingMeasurementTask: Task<Void, Never>?

    override func viewDidLayout() {
        super.viewDidLayout()
        measureAndReportHeight()
    }

    deinit {
        pendingMeasurementTask?.cancel()
    }

    private func measureAndReportHeight() {
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
        let proposedSize = CGSize(
            width: width,
            height: .greatestFiniteMagnitude
        )
        let height = max(1, sizeThatFits(in: proposedSize).height.rounded(.up))
        guard abs(lastReportedHeight - height) > 0.5 else { return }
        lastReportedHeight = height
        onLaidOutHeightChange?(height)
    }

    func invalidateContentSize(forceReport: Bool = false) {
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
            self.measureAndReportHeight()
        }
    }

    func resetReportedHeight() {
        lastReportedHeight = 0
    }
}
