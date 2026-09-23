import UIKit

/// A UITextView that reports its content height whenever layout gives it a
/// real width — including the first layout after being remounted with
/// restored draft text, and any width change thereafter.
///
/// The view always scrolls, and its own scroll pan doubles as the composer's
/// resize gesture, the way a sheet hands a drag between its scroll view and
/// its detent: a drag scrolls the text until it reaches the edge in the
/// direction of travel, then the rest of the same drag resizes the card —
/// up from the bottom edge while collapsed, down from the top edge while
/// expanded. Toggling `isScrollEnabled` with the card's height instead (the
/// earlier design) made scrolling depend on a measurement that itself
/// changes with the scroll mode, so an overflowing draft could end up
/// unscrollable. One recognizer also keeps text selection and loupe drags
/// under UIKit's native arbitration.
final class HeightReportingTextView: UITextView {
  /// While a first-send promotion moves this editor from the New Chat
  /// sheet's hosting controller into the workspace route, SwiftUI's focus
  /// bridge resigns the responder it last saw inside the disappearing
  /// sheet — ~60 ms after the editor has already been re-hosted. Refusing
  /// that resignation keeps the keyboard session continuous.
  private(set) var holdsFirstResponderForPromotion = false
  private var promotionHoldRelease: DispatchWorkItem?

  func setPromotionResponderHold(_ holds: Bool, releaseAfter delay: TimeInterval? = nil) {
    promotionHoldRelease?.cancel()
    promotionHoldRelease = nil
    holdsFirstResponderForPromotion = holds
    guard holds, let delay else { return }
    let release = DispatchWorkItem { [weak self] in
      self?.holdsFirstResponderForPromotion = false
      self?.promotionHoldRelease = nil
    }
    promotionHoldRelease = release
    DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: release)
  }

  override func resignFirstResponder() -> Bool {
    let wasFirstResponder = isFirstResponder
    if wasFirstResponder, holdsFirstResponderForPromotion {
      IOSNavigationDiagnostics.record("editor.resignFirstResponder", "refused=promotion-hold")
      return false
    }
    let result = super.resignFirstResponder()
    if wasFirstResponder, result { reportFocus() }
    if wasFirstResponder {
      // Name the caller: a keyboard that drops during first-send promotion
      // is always some reconciliation path, and the stack says which.
      let frames = Thread.callStackSymbols.dropFirst(2).prefix(14)
        .map { frame in
          // Keep the symbol, drop the addresses: "12 Codevisor 0x... $s..." → "$s..."
          frame.split(separator: " ", omittingEmptySubsequences: true).dropFirst(3).joined(separator: " ")
        }
        .joined(separator: " <- ")
      IOSNavigationDiagnostics.record("editor.resignFirstResponder", "result=\(result) stack=\(frames)")
    }
    return result
  }

  override func becomeFirstResponder() -> Bool {
    let result = super.becomeFirstResponder()
    IOSNavigationDiagnostics.record("editor.becomeFirstResponder", "result=\(result)")
    if result { reportFocus() }
    return result
  }

  /// Focus drives the composer's compact preview. UIKit can change it from
  /// inside a SwiftUI update (a focus request, a promotion re-host), so the
  /// callback always defers to the next main-actor turn and reports the
  /// responder state at that moment rather than the transition.
  var onFocusChange: ((Bool) -> Void)?

  func reportFocus() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.onFocusChange?(self.isFirstResponder)
    }
  }

  var onContentHeightChange: ((CGFloat) -> Void)?
  var onPasteAttachmentEvent: ((ComposerPasteEvent) -> Void)?
  /// Which edge hands a drag to the card: the bottom edge grows a collapsed
  /// card, the top edge shrinks an expanded one.
  var isComposerExpanded = false
  /// The composer's resize drag, measured from the point where the scroll
  /// reached its edge, in window coordinates so the view's own growth under
  /// the finger can't feed back into the translation.
  var onResizePanChanged: ((CGFloat) -> Void)?
  /// (translation, velocity) at release, points and points/second — the
  /// same units as SwiftUI's DragGesture, so both gestures share one
  /// commit path.
  var onResizePanEnded: ((CGFloat, CGFloat) -> Void)?
  var onResizePanCancelled: (() -> Void)?
  var onFocusRequestFulfilled: ((UUID) -> Void)?
  /// A hardware keyboard's Return sends, as on macOS; Shift-Return still
  /// inserts a line break. Key commands never fire for the on-screen
  /// keyboard, whose Return stays text input, and a pending composition
  /// (an input method's marked text) keeps Return for committing it.
  var onHardwareReturn: (() -> Void)?

  override var keyCommands: [UIKeyCommand]? {
    let inherited = super.keyCommands ?? []
    guard onHardwareReturn != nil, markedTextRange == nil else { return inherited }
    let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(sendFromHardwareKeyboard))
    send.wantsPriorityOverSystemBehavior = true
    let commandSend = UIKeyCommand(
      title: "Send Message", action: #selector(sendFromHardwareKeyboard), input: "\r", modifierFlags: .command)
    commandSend.wantsPriorityOverSystemBehavior = true
    return inherited + [send, commandSend]
  }

  @objc private func sendFromHardwareKeyboard() {
    onHardwareReturn?()
  }

  private var lastReportedHeight: CGFloat = 0
  private var lastLayoutHeight: CGFloat = 0
  /// A request can arrive before SwiftUI has inserted this view into a
  /// window. Keep it pending until `didMoveToWindow`, then remember that it
  /// was fulfilled so later updates cannot reopen a dismissed keyboard.
  private var pendingFocusRequest: UUID?
  private var fulfilledFocusRequest: UUID?

  private enum ResizeEdge {
    /// Collapsed, scrolled to the bottom, finger moving up.
    case expand
    /// Expanded, scrolled to the top, finger moving down.
    case collapse
  }

  /// Non-nil while the current drag is resizing the card instead of
  /// scrolling the text.
  private var resizeEdge: ResizeEdge?
  /// Pan translation at the moment the drag reached the edge.
  private var resizeOrigin: CGFloat = 0
  private var previousPanTranslation: CGFloat = 0

  /// The offset the text is held at while the card resizes. The scroll
  /// view's delegate also ends the drag here, so no momentum carries the
  /// text past it after release.
  var resizeHoldingOffset: CGPoint? {
    resizeEdge.map(holdingOffset)
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    isScrollEnabled = true
    // UIScrollView won't begin its pan over content that can't scroll.
    // Text that fits still needs the drag to resize the card; the pan
    // handler keeps such text from visibly rubber-banding.
    alwaysBounceVertical = true
    // The scroll pan's own handler runs first, so this one sees each
    // frame after UIKit has applied it and can take the movement back.
    panGestureRecognizer.addTarget(self, action: #selector(handleScrollPan))
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

  private var minimumOffsetY: CGFloat { -adjustedContentInset.top }

  private var maximumOffsetY: CGFloat {
    max(minimumOffsetY, contentSize.height - bounds.height + adjustedContentInset.bottom)
  }

  private func holdingOffset(for edge: ResizeEdge) -> CGPoint {
    CGPoint(x: contentOffset.x, y: edge == .expand ? maximumOffsetY : minimumOffsetY)
  }

  /// Text that fits sits at both edges at once, so any vertical drag on it
  /// resizes the card.
  private func edgeClaimingDrag(fingerDelta delta: CGFloat) -> ResizeEdge? {
    if delta < 0, !isComposerExpanded, contentOffset.y >= maximumOffsetY - 1 {
      return .expand
    }
    if delta > 0, isComposerExpanded, contentOffset.y <= minimumOffsetY + 1 {
      return .collapse
    }
    return nil
  }

  private func hold(_ edge: ResizeEdge) {
    let offset = holdingOffset(for: edge)
    if abs(contentOffset.y - offset.y) > 0.25 {
      contentOffset = offset
    }
  }

  @objc private func handleScrollPan(_ pan: UIPanGestureRecognizer) {
    let space = window ?? self
    let translation = pan.translation(in: space).y
    switch pan.state {
    case .began:
      resizeEdge = nil
      previousPanTranslation = translation
    case .changed:
      let delta = translation - previousPanTranslation
      previousPanTranslation = translation
      if let edge = resizeEdge {
        let resize = translation - resizeOrigin
        // Reversing past the point where the resize began gives the
        // drag back to the text, so one gesture can resize, then scroll.
        if (edge == .expand && resize > 0) || (edge == .collapse && resize < 0) {
          resizeEdge = nil
          onResizePanChanged?(0)
        } else {
          hold(edge)
          onResizePanChanged?(resize)
        }
      } else if let edge = edgeClaimingDrag(fingerDelta: delta) {
        resizeEdge = edge
        // UIKit already scrolled by this frame's movement; count it
        // toward the resize and take the scroll back.
        resizeOrigin = translation - delta
        hold(edge)
        onResizePanChanged?(delta)
      } else if maximumOffsetY <= minimumOffsetY {
        // Text that fits has nothing to scroll; don't let the always-on
        // bounce drag it around inside the card.
        hold(.collapse)
      }
    case .ended:
      guard let edge = resizeEdge else { return }
      hold(edge)
      resizeEdge = nil
      onResizePanEnded?(translation - resizeOrigin, pan.velocity(in: space).y)
    case .cancelled, .failed:
      guard resizeEdge != nil else { return }
      resizeEdge = nil
      onResizePanCancelled?()
    default:
      break
    }
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // The card resizes under the finger; keep the text pinned to the edge
    // the drag came from rather than letting the new bounds shift it.
    if let resizeEdge { hold(resizeEdge) }
    // Leaving the compact preview grows the editor from nothing after it
    // has already taken focus. Bring the caret into view at its real size.
    if lastLayoutHeight < 1, bounds.height >= 1, isFirstResponder, resizeEdge == nil {
      scrollRangeToVisible(selectedRange)
    }
    lastLayoutHeight = bounds.height
    reportContentHeight()
  }

  override var contentSize: CGSize {
    didSet { reportContentHeight() }
  }

  /// A scrolling text view's content size is its full text height, insets
  /// included, whatever its current bounds.
  func reportContentHeight() {
    guard bounds.width > 0 else { return }
    let height = contentSize.height
    guard abs(height - lastReportedHeight) > 0.5 else { return }
    lastReportedHeight = height
    onContentHeightChange?(height)
  }
}
