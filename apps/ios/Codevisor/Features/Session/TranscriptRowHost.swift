import SwiftUI
import TranscriptKit
import UIKit

/// A stable, identity-bound row host. Its SwiftUI content owns natural height;
/// the virtualizer supplies only document position and width.
@MainActor
final class TranscriptRowHost: UIView {
    private let contentController = TranscriptContentHostingController(
        rootView: AnyView(EmptyView()),
    )
    private var contentHost: UIView {
        contentController.view
    }

    private lazy var contentWidthConstraint = contentHost.widthAnchor.constraint(
        equalToConstant: 1,
    )

    private(set) var representedRow: TranscriptVirtualRow?
    private(set) var isPresentationReady = false
    // Rows without inline previews have no preference value to emit and are
    // ready by definition. A pending preview reports a nonzero count during
    // the same SwiftUI layout pass, before the deferred height measurement.
    private(set) var isAttachmentGeometryReady = true
    var onMeasuredHeight: ((TranscriptRowMeasurement) -> Void)?

    init(parent: UIViewController) {
        super.init(frame: .zero)
        backgroundColor = .clear
        // The virtualizer is the only owner of row geometry. Until a natural
        // height has been committed, keep the hosted content inside the
        // current ledger frame so an estimate can never paint over its
        // neighbor.
        clipsToBounds = true

        parent.addChild(contentController)
        let hostedView = contentController.view!
        hostedView.backgroundColor = .clear
        hostedView.clipsToBounds = false
        hostedView.translatesAutoresizingMaskIntoConstraints = false
        hostedView.setContentHuggingPriority(.required, for: .vertical)
        hostedView.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(hostedView)
        NSLayoutConstraint.activate([
            hostedView.topAnchor.constraint(equalTo: topAnchor),
            hostedView.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentWidthConstraint,
        ])
        contentController.didMove(toParent: parent)
        contentController.onLaidOutHeightChange = { [weak self] height in
            self?.contentHeightDidChange(height)
        }
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        if syncContentWidth() {
            contentController.invalidateContentSize(forceReport: true)
        }
        super.layoutSubviews()
    }

    @discardableResult
    func syncContentWidth() -> Bool {
        let width = max(1, bounds.width)
        guard abs(contentWidthConstraint.constant - width) > 0.5 else { return false }
        contentWidthConstraint.constant = width
        return true
    }

    func install(row: TranscriptVirtualRow, rootView: AnyView, force: Bool = false) {
        let representsDifferentRow = representedRow?.layoutKey != row.layoutKey
        let needsRoot =
            force
            || representedRow?.content != row.content
            || representedRow?.measurementRevision != row.measurementRevision
        representedRow = row
        guard needsRoot else { return }
        isPresentationReady = false
        isAttachmentGeometryReady = true
        // An optimistic message can become settled while its lift is still in
        // flight. Preserve the wrapper animation when the stable row identity
        // is unchanged; only reused hosts may discard another row's animation.
        if representsDifferentRow {
            layer.removeAnimation(forKey: "codevisor.user-send")
        }
        contentController.installRootView(rootView)
    }

    func requestContentMeasurement(forceReport: Bool = true) {
        contentController.invalidateContentSize(forceReport: forceReport)
    }

    func resetReportedContentHeight() {
        isPresentationReady = false
        contentController.resetReportedHeight()
    }

    @discardableResult
    func setAttachmentGeometryReady(_ ready: Bool) -> Bool {
        guard isAttachmentGeometryReady != ready else { return false }
        isAttachmentGeometryReady = ready
        // A placeholder may already have produced a measurement. Require one
        // fresh report after the final aspect ratio (or locked fallback) wins.
        isPresentationReady = false
        if ready {
            contentController.invalidateContentSize(forceReport: true)
        }
        return true
    }

    func detachFromParent() {
        contentController.onLaidOutHeightChange = nil
        guard contentController.parent != nil else { return }
        contentController.willMove(toParent: nil)
        contentController.view.removeFromSuperview()
        contentController.removeFromParent()
    }

    private func contentHeightDidChange(_ rawHeight: CGFloat) {
        guard let row = representedRow else { return }
        let scale = TranscriptPixelGeometry.displayScale(for: contentHost)
        let height = max(1, TranscriptPixelGeometry.ceil(rawHeight, scale: scale))

        // Do not resize this wrapper independently. The callback commits the
        // height, following offsets, document size, and every mounted frame in
        // one non-animated virtual-layout transaction before UIKit paints.
        isPresentationReady = true
        onMeasuredHeight?(
            .init(
                key: row.layoutKey,
                revision: row.measurementRevision,
                rowWidthHalfPoints: Int((contentWidthConstraint.constant * 2).rounded()),
                height: height,
            ))
    }
}
