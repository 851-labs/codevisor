import UIKit

/// A UITextView that reports its fitting content height whenever layout
/// gives it a real width — including the first layout after being remounted
/// with restored draft text, and any width change thereafter.
///
/// It also carries the composer's grab-anywhere resize pan. Living at the
/// UIKit level, the pan takes part in the text view's own gesture
/// arbitration — unlike a SwiftUI `simultaneousGesture` layered on top,
/// which ran alongside every selection and loupe drag and made text
/// interaction feel non-native. `gestureRecognizerShouldBegin` is the whole
/// contract: begin only for a predominantly vertical pull, never while the
/// text can scroll, and never for a touch sequence a text interaction
/// already owns.
final class HeightReportingTextView: UITextView {
    var onContentHeightChange: ((CGFloat) -> Void)?
    var onPasteAttachmentEvent: ((ComposerPasteEvent) -> Void)?
    /// The composer's resize pan, reported in window coordinates so the
    /// view's own growth under the finger can't feed back into the
    /// translation.
    var onResizePanChanged: ((CGFloat) -> Void)?
    /// (translation, velocity) at release, points and points/second — the
    /// same units as SwiftUI's DragGesture, so both gestures share one
    /// commit path.
    var onResizePanEnded: ((CGFloat, CGFloat) -> Void)?
    var onResizePanCancelled: (() -> Void)?
    var onFocusRequestFulfilled: ((UUID) -> Void)?

    private var lastReportedHeight: CGFloat = 0
    /// A request can arrive before SwiftUI has inserted this view into a
    /// window. Keep it pending until `didMoveToWindow`, then remember that it
    /// was fulfilled so later updates cannot reopen a dismissed keyboard.
    private var pendingFocusRequest: UUID?
    private var fulfilledFocusRequest: UUID?

    private lazy var expansionPan: UIPanGestureRecognizer = {
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handleExpansionPan))
        pan.maximumNumberOfTouches = 1
        return pan
    }()

    override init(frame: CGRect, textContainer: NSTextContainer?) {
        super.init(frame: frame, textContainer: textContainer)
        addGestureRecognizer(expansionPan)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    func requestInitialFocus(_ request: UUID?) {
        guard let request, request != fulfilledFocusRequest else { return }
        pendingFocusRequest = request
        fulfillPendingFocusRequestIfPossible()
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        fulfillPendingFocusRequestIfPossible()
    }

    /// Keyboard paste suggestions use the responder-level item-provider API
    /// and do not consistently enter `UITextPasteDelegate`. Intercept only
    /// attachment-capable providers here; ordinary text remains UIKit-owned.
    override func paste(itemProviders: [NSItemProvider]) {
        guard let onPasteAttachmentEvent else {
            super.paste(itemProviders: itemProviders)
            return
        }
        let attachmentProviders = itemProviders.filter {
            ComposerPasteProviderLoader.canLoadAttachment(from: $0)
        }
        let defaultProviders = itemProviders.filter {
            !ComposerPasteProviderLoader.canLoadAttachment(from: $0)
        }

        if !attachmentProviders.isEmpty {
            ComposerPasteProviderLoader.logInvocation(
                route: "responder",
                providers: attachmentProviders
            )
            for provider in attachmentProviders {
                ComposerPasteProviderLoader.startLoading(
                    from: provider,
                    onEvent: onPasteAttachmentEvent
                )
            }
        }
        if !defaultProviders.isEmpty {
            super.paste(itemProviders: defaultProviders)
        }
    }

    private func fulfillPendingFocusRequestIfPossible() {
        guard let request = pendingFocusRequest,
            window != nil,
            isEditable
        else { return }
        guard becomeFirstResponder() else { return }
        fulfilledFocusRequest = request
        pendingFocusRequest = nil
        // UIKit may attach during a SwiftUI update. Acknowledge on the next
        // main-actor turn so the source can clear the request safely.
        Task { @MainActor [onFocusRequestFulfilled] in
            onFocusRequestFulfilled?(request)
        }
    }

    override func gestureRecognizerShouldBegin(_ gestureRecognizer: UIGestureRecognizer) -> Bool {
        guard gestureRecognizer === expansionPan else {
            // Text interactions and the scroll pan keep their own rules.
            return super.gestureRecognizerShouldBegin(gestureRecognizer)
        }
        // Overflowing text owns vertical drags for scrolling; the card is
        // still grabbable from its toolbar row.
        guard !isScrollEnabled else { return false }
        // Only a predominantly vertical pull reads as a resize; sideways
        // drags stay available to text interactions.
        let velocity = expansionPan.velocity(in: self)
        guard abs(velocity.y) > abs(velocity.x) else { return false }
        // Never steal a touch sequence a text gesture already owns — an
        // active loupe drag or selection-handle drag keeps the card still.
        let textGestureActive = (gestureRecognizers ?? []).contains { other in
            other !== expansionPan && (other.state == .began || other.state == .changed)
        }
        return !textGestureActive
    }

    @objc private func handleExpansionPan(_ pan: UIPanGestureRecognizer) {
        let space = window ?? self
        switch pan.state {
        case .changed:
            onResizePanChanged?(pan.translation(in: space).y)
        case .ended:
            onResizePanEnded?(pan.translation(in: space).y, pan.velocity(in: space).y)
        case .cancelled, .failed:
            onResizePanCancelled?()
        default:
            break
        }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        reportContentHeight()
    }

    func reportContentHeight() {
        let width = bounds.width
        guard width > 0 else { return }
        let height = sizeThatFits(
            CGSize(width: width, height: .greatestFiniteMagnitude)
        ).height
        guard abs(height - lastReportedHeight) > 0.5 else { return }
        lastReportedHeight = height
        onContentHeightChange?(height)
    }
}
