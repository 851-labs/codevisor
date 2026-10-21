import UIKit

final class HeightReportingTextView: UITextView {
  private(set) var holdsFirstResponderForPromotion = false
  private var promotionHoldRelease: DispatchWorkItem?
  private var sentTextColor: UIColor??
  private var sentTextReveal: DispatchWorkItem?

  func hideSentText() {
    guard !text.isEmpty, sentTextColor == nil else { return }
    sentTextColor = .some(textColor)
    textColor = .clear
    let reveal = DispatchWorkItem { [weak self] in self?.revealSentText() }
    sentTextReveal = reveal
    DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: reveal)
  }

  private func revealSentText() {
    sentTextReveal?.cancel()
    sentTextReveal = nil
    guard let color = sentTextColor else { return }
    sentTextColor = nil
    textColor = color
  }

  override var text: String! {
    didSet { revealSentText() }
  }

  func textDidChangeByUser() {
    revealSentText()
  }

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
      let frames = Thread.callStackSymbols.dropFirst(2).prefix(14)
        .map { frame in
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

  var onFocusChange: ((Bool) -> Void)?

  func reportFocus() {
    Task { @MainActor [weak self] in
      guard let self else { return }
      self.onFocusChange?(self.isFirstResponder)
    }
  }

  var onContentHeightChange: ((CGFloat) -> Void)?
  var onPasteAttachmentEvent: ((ComposerPasteEvent) -> Void)?
  var isComposerExpanded = false
  var onResizePanChanged: ((CGFloat) -> Void)?
  var onResizePanEnded: ((CGFloat, CGFloat) -> Void)?
  var onResizePanCancelled: (() -> Void)?
  var onFocusRequestFulfilled: ((UUID) -> Void)?
  var onHardwareReturn: (() -> Void)?
  var onHardwareQueue: (() -> Void)?

  override var keyCommands: [UIKeyCommand]? {
    let inherited = super.keyCommands ?? []
    guard onHardwareReturn != nil, markedTextRange == nil else { return inherited }
    let send = UIKeyCommand(input: "\r", modifierFlags: [], action: #selector(sendFromHardwareKeyboard))
    send.wantsPriorityOverSystemBehavior = true
    return inherited + [send, commandReturnKeyCommand]
  }

  private var commandReturnKeyCommand: UIKeyCommand {
    let title = onHardwareQueue == nil ? "Send Message" : "Queue Message"
    let command = UIKeyCommand(
      title: title, action: #selector(commandReturnFromHardwareKeyboard), input: "\r", modifierFlags: .command)
    command.wantsPriorityOverSystemBehavior = true
    return command
  }

  @objc private func sendFromHardwareKeyboard() {
    onHardwareReturn?()
  }

  @objc private func commandReturnFromHardwareKeyboard() {
    (onHardwareQueue ?? onHardwareReturn)?()
  }

  private var lastReportedHeight: CGFloat = 0
  private var lastLayoutHeight: CGFloat = 0
  private var pendingFocusRequest: UUID?
  private var fulfilledFocusRequest: UUID?

  private enum ResizeEdge {
    case expand
    case collapse
  }

  private var resizeEdge: ResizeEdge?
  private var resizeOrigin: CGFloat = 0
  private var previousPanTranslation: CGFloat = 0

  var resizeHoldingOffset: CGPoint? {
    resizeEdge.map(holdingOffset)
  }

  override init(frame: CGRect, textContainer: NSTextContainer?) {
    super.init(frame: frame, textContainer: textContainer)
    isScrollEnabled = true
    alwaysBounceVertical = true
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

  override func canPerformAction(_ action: Selector, withSender sender: Any?) -> Bool {
    if action == #selector(paste(_:)), isEditable, onPasteAttachmentEvent != nil,
      ComposerPasteProviderLoader.pasteboardHasAttachment()
    {
      return true
    }
    return super.canPerformAction(action, withSender: sender)
  }

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
        if (edge == .expand && resize > 0) || (edge == .collapse && resize < 0) {
          resizeEdge = nil
          onResizePanChanged?(0)
        } else {
          hold(edge)
          onResizePanChanged?(resize)
        }
      } else if let edge = edgeClaimingDrag(fingerDelta: delta) {
        resizeEdge = edge
        resizeOrigin = translation - delta
        hold(edge)
        onResizePanChanged?(delta)
      } else if maximumOffsetY <= minimumOffsetY {
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
    if let resizeEdge { hold(resizeEdge) }
    if lastLayoutHeight < 1, bounds.height >= 1, isFirstResponder, resizeEdge == nil {
      scrollRangeToVisible(selectedRange)
    }
    lastLayoutHeight = bounds.height
    reportContentHeight()
  }

  override var contentSize: CGSize {
    didSet { reportContentHeight() }
  }

  func reportContentHeight() {
    guard bounds.width > 0 else { return }
    let height = contentSize.height
    guard abs(height - lastReportedHeight) > 0.5 else { return }
    lastReportedHeight = height
    onContentHeightChange?(height)
  }
}
