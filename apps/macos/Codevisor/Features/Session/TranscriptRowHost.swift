import AppKit
import QuartzCore
import SwiftUI

/// A mounted row's SwiftUI content owns its natural height. The virtualizer
/// supplies only the row's top position and width, then observes the hosting
/// view's laid-out height to move later rows. Estimated outer heights are never
/// imposed back onto mounted content.
@MainActor
final class TranscriptRowHost: NSView {
    private let contentController = TranscriptContentHostingController(rootView: AnyView(EmptyView()))
    private var contentHost: NSView { contentController.view }
    private lazy var contentWidthConstraint = contentHost.widthAnchor.constraint(equalToConstant: 1)
    private lazy var contentHeightConstraint = contentHost.heightAnchor.constraint(equalToConstant: 1)
    var onHeightChange: ((CGFloat) -> Void)?
    private(set) var isPresentationReady = false
    private(set) var isAttachmentGeometryReady = true

    override var isFlipped: Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = NSColor.clear.cgColor
        // The virtualizer is the only owner of row geometry. Until a natural
        // height has been committed, keep hosted content inside the current
        // ledger frame so an estimate can never paint over its neighbor.
        layer?.masksToBounds = true
        contentHost.translatesAutoresizingMaskIntoConstraints = false
        contentController.sizingOptions = [.intrinsicContentSize]
        contentHost.setContentHuggingPriority(.required, for: .vertical)
        contentHost.setContentCompressionResistancePriority(.required, for: .vertical)
        addSubview(contentHost)
        NSLayoutConstraint.activate([
            contentHost.topAnchor.constraint(equalTo: topAnchor),
            contentHost.leadingAnchor.constraint(equalTo: leadingAnchor),
            contentWidthConstraint,
            contentHeightConstraint,
        ])
        contentController.onLaidOutHeightChange = { [weak self] height in
            self?.contentHeightDidChange(height)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        if syncContentWidth() {
            contentController.invalidateContentSize(forceReport: true)
        }
        super.layout()
    }

    /// Pushes the row's current width into the content constraint without
    /// waiting for AppKit's layout pass, returning whether it moved.
    ///
    /// Mounting sets the host's frame and its content in the same main-actor
    /// turn, but `frame` only marks the view as needing layout — `layout()`
    /// runs later. The first measurement would therefore race against the 1pt
    /// placeholder width, so mounting calls this explicitly between
    /// positioning the host and installing its root view.
    @discardableResult
    func syncContentWidth() -> Bool {
        let width = max(1, bounds.width)
        guard abs(contentWidthConstraint.constant - width) > 0.5 else { return false }
        contentWidthConstraint.constant = width
        return true
    }

    var rootView: AnyView {
        get { contentController.rootView }
        set {
            isPresentationReady = false
            isAttachmentGeometryReady = true
            contentController.rootView = newValue
            contentController.invalidateContentSize(forceReport: true)
        }
    }

    func prepareForMountedRow() {
        layer?.removeAnimation(forKey: "codevisor.user-send")
        layer?.removeAnimation(forKey: "codevisor.send-history-shift")
        layer?.removeAnimation(forKey: "codevisor.send-assistant-hold")
        layer?.opacity = 1
        isPresentationReady = false
        isAttachmentGeometryReady = true
        contentController.resetReportedHeight()
    }

    func requestContentMeasurement(forceReport: Bool = true) {
        contentController.invalidateContentSize(forceReport: forceReport)
    }

    /// Forces the next layout pass to re-report the content height even when
    /// it is unchanged. Used when a row's measurement revision moves under a
    /// mounted host: the report itself is the signal that lets the virtualizer
    /// clear the stale flag and rewrite revision-keyed caches, so it must not
    /// be swallowed by the unchanged-height dedupe.
    func resetReportedContentHeight() {
        isPresentationReady = false
        contentController.resetReportedHeight()
    }

    @discardableResult
    func setAttachmentGeometryReady(_ ready: Bool) -> Bool {
        guard isAttachmentGeometryReady != ready else { return false }
        isAttachmentGeometryReady = ready
        // A fallback placeholder may already have produced a measurement.
        // Require a fresh report after the final ratio (or locked fallback)
        // wins, even when the resulting row height happens to be unchanged.
        isPresentationReady = false
        if ready {
            contentController.invalidateContentSize(forceReport: true)
        }
        return true
    }

    private func contentHeightDidChange(_ height: CGFloat) {
        // Keep the hosted content's natural height current, but never resize
        // this wrapper independently. The callback commits this height,
        // following offsets, document size, and every mounted frame in one
        // non-animated virtual-layout transaction before AppKit paints.
        if abs(contentHeightConstraint.constant - height) > 0.5 {
            contentHeightConstraint.constant = height
        }
        isPresentationReady = true
        onHeightChange?(height)
    }
}
