import AppKit
import QuartzCore
import SwiftUI

/// A mounted row's SwiftUI content owns its natural height. The virtualizer
/// supplies only the row's top position and width, then observes the hosting
/// view's laid-out height to move later rows. Estimated outer heights are never
/// imposed back onto mounted content.
@MainActor
final class TranscriptRowHost: TranscriptMountedRowHost {
    private let contentController = TranscriptContentHostingController(rootView: AnyView(EmptyView()))
    private var contentHost: NSView { contentController.view }
    private lazy var contentWidthConstraint = contentHost.widthAnchor.constraint(equalToConstant: 1)
    private lazy var contentHeightConstraint = contentHost.heightAnchor.constraint(equalToConstant: 1)
    private var presentationReady = false
    private var attachmentGeometryReady = true
    private(set) var hasAttemptedPresentation = false
    private var hasStableContentGeometry = false
    private var canSkipContentLayout = false
    private var needsStableConstraintPass = false

    override var isPresentationReady: Bool { presentationReady }
    override var isAttachmentGeometryReady: Bool { attachmentGeometryReady }

    override var needsRunwayPreparation: Bool {
        !presentationReady
            && attachmentGeometryReady
            && (!hasAttemptedPresentation || needsStableConstraintPass)
    }

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
        contentController.onLayoutCompleted = { [weak self] in
            guard let self, self.hasStableContentGeometry else { return }
            if self.needsStableConstraintPass {
                self.needsStableConstraintPass = false
                self.needsLayout = true
                return
            }
            self.presentationReady = true
            self.canSkipContentLayout = true
        }
    }

    override func performanceIdentityDidChange() {
        contentController.performanceIdentity = performanceIdentity
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layout() {
        let width = max(1, bounds.width)
        if canSkipContentLayout,
            abs(contentWidthConstraint.constant - width) <= 0.5
        {
            contentHost.needsLayout = false
            return
        }
        if syncContentWidth() {
            canSkipContentLayout = false
            hasStableContentGeometry = false
            needsStableConstraintPass = false
            contentController.invalidateContentSize(forceReport: true)
        }
        // AppKit asks every descendant of the scrolling document to lay out
        // surprisingly often, even when only the clip view's origin moved.
        // A transcript row with exact, reported geometry has nothing to do in
        // that pass: its width, root, and explicit content height are unchanged.
        // Explicit content invalidations below reopen the layout path.
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
    override func syncContentWidth() -> Bool {
        let width = max(1, bounds.width)
        guard abs(contentWidthConstraint.constant - width) > 0.5 else { return false }
        contentWidthConstraint.constant = width
        return true
    }

    var rootView: AnyView {
        get { contentController.rootView }
        set { installRootView(newValue, knownHeight: nil) }
    }

    func installRootView(_ rootView: AnyView, knownHeight: CGFloat?) {
        presentationReady = false
        attachmentGeometryReady = true
        hasAttemptedPresentation = false
        hasStableContentGeometry = knownHeight != nil
        canSkipContentLayout = false
        needsStableConstraintPass = false
        if let knownHeight {
            contentHeightConstraint.constant = knownHeight
            contentController.useKnownContentHeight(knownHeight)
        } else {
            contentController.resetReportedHeight()
        }
        // Install the exact-height contract before replacing the SwiftUI root
        // so a synchronous hosting-controller layout cannot race through the
        // expensive intrinsic-size path for an already measured settled row.
        contentController.rootView = rootView
        if knownHeight == nil {
            contentController.invalidateContentSize(forceReport: true)
        }
    }

    override func prepareForMountedRow() {
        layer?.removeAnimation(forKey: "codevisor.user-send")
        layer?.removeAnimation(forKey: "codevisor.send-history-shift")
        layer?.removeAnimation(forKey: "codevisor.send-assistant-hold")
        layer?.opacity = 1
        presentationReady = false
        attachmentGeometryReady = true
        hasAttemptedPresentation = false
        hasStableContentGeometry = false
        canSkipContentLayout = false
        needsStableConstraintPass = false
        contentController.resetReportedHeight()
    }

    override func requestContentMeasurement(forceReport: Bool = true) {
        hasStableContentGeometry = false
        canSkipContentLayout = false
        needsStableConstraintPass = false
        hasAttemptedPresentation = false
        contentController.invalidateContentSize(forceReport: forceReport)
    }

    /// A viewport row is correctness-critical, unlike an offscreen runway row.
    /// Flush its pending host layout before AppKit presents the current scroll
    /// frame so a newly installed SwiftUI root cannot leave a transparent hole.
    override func prepareForImmediatePresentation() {
        hasAttemptedPresentation = true
        canSkipContentLayout = false
        needsLayout = true
        contentHost.needsLayout = true
        // `layoutSubtreeIfNeeded()` recursively flushes the hosting view. The
        // previous second explicit content-host pass dirtied and laid out the
        // same SwiftUI tree twice on the critical viewport-entry frame.
        layoutSubtreeIfNeeded()
    }

    @discardableResult
    override func setAttachmentGeometryReady(_ ready: Bool) -> Bool {
        guard attachmentGeometryReady != ready else { return false }
        attachmentGeometryReady = ready
        // A fallback placeholder may already have produced a measurement.
        // Require a fresh report after the final ratio (or locked fallback)
        // wins, even when the resulting row height happens to be unchanged.
        presentationReady = false
        hasStableContentGeometry = false
        canSkipContentLayout = false
        needsStableConstraintPass = false
        if ready {
            hasAttemptedPresentation = false
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
        hasStableContentGeometry = true
        presentationReady = false
        canSkipContentLayout = false
        needsStableConstraintPass = true
        onHeightChange?(height)
    }
}
