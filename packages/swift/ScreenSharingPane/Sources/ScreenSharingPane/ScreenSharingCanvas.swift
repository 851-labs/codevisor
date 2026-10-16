#if os(iOS)
  import ScreenSharing
  import ScreenSharingWebRTC
  import SwiftUI
  import UIKit

  struct ScreenSharingCanvas: UIViewRepresentable {
    let model: ScreenSharingPaneModel

    func makeUIView(context: Context) -> ScreenSharingCanvasView { ScreenSharingCanvasView(model: model) }

    func updateUIView(_ view: ScreenSharingCanvasView, context: Context) {
      view.attach(model.receiver)
      view.showKeyboard(model.keyboardShown)
    }

    static func dismantleUIView(_ view: ScreenSharingCanvasView, coordinator: ()) { view.stop() }
  }

  final class ScreenSharingCanvasView: UIView, UIScrollViewDelegate, UIGestureRecognizerDelegate {
    private let model: ScreenSharingPaneModel
    private let scrollView = UIScrollView()
    private let content = UIView()
    private let keyInput: ScreenSharingKeyInputView
    private var metal: ScreenSharingMetalView?
    private weak var mailbox: ScreenSharingFrameMailbox?
    private var videoSize: CGSize?
    private let twoFingerPan = UIPanGestureRecognizer()
    private var scrollZoom: CGFloat = 1
    private var scrollTranslation: CGPoint = .zero
    private var scrollSuppressed = false
    private let dragPan = UIPanGestureRecognizer()
    private var dragFinger: CGPoint?
    private var dragLink: CADisplayLink?
    private var heldGesture: UIGestureRecognizer?

    init(model: ScreenSharingPaneModel) {
      self.model = model
      keyInput = ScreenSharingKeyInputView(model: model)
      super.init(frame: .zero)
      backgroundColor = .clear
      scrollView.delegate = self
      scrollView.minimumZoomScale = 1
      scrollView.maximumZoomScale = 5
      scrollView.bouncesZoom = true
      scrollView.showsVerticalScrollIndicator = false
      scrollView.showsHorizontalScrollIndicator = false
      scrollView.contentInsetAdjustmentBehavior = .never
      scrollView.panGestureRecognizer.isEnabled = false
      scrollView.accessibilityIdentifier = "screen-sharing.canvas"
      addSubview(scrollView)
      scrollView.addSubview(content)
      addSubview(keyInput)
      installGestures()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }

    func attach(_ receiver: ScreenSharingReceiver?) {
      guard let receiver else {
        detachVideo()
        return
      }
      guard receiver.mailbox !== mailbox else { return }
      detachVideo()
      mailbox = receiver.mailbox
      guard
        let metal = try? ScreenSharingMetalView(
          mailbox: receiver.mailbox, metrics: receiver.metrics, renderOnArrival: true)
      else { return }
      metal.isUserInteractionEnabled = false
      metal.frame = content.bounds
      metal.autoresizingMask = [.flexibleWidth, .flexibleHeight]
      metal.onFrameSize = { [weak self] size in self?.frameSizeChanged(size) }
      content.addSubview(metal)
      self.metal = metal
    }

    func showKeyboard(_ shown: Bool) {
      if shown {
        if !keyInput.isFirstResponder { _ = keyInput.becomeFirstResponder() }
      } else if keyInput.isFirstResponder {
        _ = keyInput.resignFirstResponder()
      }
    }

    func stop() {
      cancelDrag()
      detachVideo()
      _ = keyInput.resignFirstResponder()
    }

    override func didMoveToWindow() {
      super.didMoveToWindow()
      guard window != nil else { return }
      holdContentPopGesture()
      if !model.keyboardShown { _ = becomeFirstResponder() }
    }

    override func willMove(toWindow newWindow: UIWindow?) {
      super.willMove(toWindow: newWindow)
      guard newWindow == nil else { return }
      cancelDrag()
      releaseContentPopGesture()
    }

    private func holdContentPopGesture() {
      guard heldGesture == nil else { return }
      var responder: UIResponder? = next
      while let current = responder, !(current is UIViewController) { responder = current.next }
      guard
        let gesture = (responder as? UIViewController)?.navigationController?.interactiveContentPopGestureRecognizer,
        gesture.isEnabled
      else { return }
      gesture.isEnabled = false
      heldGesture = gesture
    }

    private func releaseContentPopGesture() {
      heldGesture?.isEnabled = true
      heldGesture = nil
    }

    override func layoutSubviews() {
      super.layoutSubviews()
      scrollView.frame = bounds
      layoutContent()
    }

    private func detachVideo() {
      metal?.stop()
      metal?.removeFromSuperview()
      metal = nil
      mailbox = nil
    }

    private func frameSizeChanged(_ size: CGSize) {
      guard size.width > 0, size.height > 0 else { return }
      model.presentedFirstFrame()
      guard size != videoSize else { return }
      videoSize = size
      scrollView.setZoomScale(1, animated: false)
      setNeedsLayout()
    }

    private func layoutContent() {
      guard scrollView.zoomScale == 1 || content.bounds.isEmpty else {
        centerContent()
        return
      }
      let available = bounds.size
      guard available.width > 0, available.height > 0 else { return }
      let video = videoSize ?? available
      let scale = min(available.width / video.width, available.height / video.height)
      let fitted = CGSize(width: (video.width * scale).rounded(), height: (video.height * scale).rounded())
      content.bounds = CGRect(origin: .zero, size: fitted)
      content.transform = .identity
      content.frame = CGRect(origin: .zero, size: fitted)
      metal?.frame = content.bounds
      scrollView.contentSize = fitted
      centerContent()
    }

    private func centerContent() {
      let size = scrollView.contentSize
      let x = max(0, (scrollView.bounds.width - size.width) / 2)
      let y = max(0, (scrollView.bounds.height - size.height) / 2)
      scrollView.contentInset = UIEdgeInsets(top: y, left: x, bottom: y, right: x)
    }

    func viewForZooming(in scrollView: UIScrollView) -> UIView? { content }

    func scrollViewDidZoom(_ scrollView: UIScrollView) { centerContent() }

    private func installGestures() {
      let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
      let secondaryTap = UITapGestureRecognizer(target: self, action: #selector(secondaryTapped(_:)))
      secondaryTap.numberOfTouchesRequired = 2
      dragPan.addTarget(self, action: #selector(dragged(_:)))
      dragPan.minimumNumberOfTouches = 1
      dragPan.maximumNumberOfTouches = 1
      twoFingerPan.addTarget(self, action: #selector(twoFingerPanned(_:)))
      twoFingerPan.minimumNumberOfTouches = 2
      twoFingerPan.maximumNumberOfTouches = 2
      twoFingerPan.delegate = self
      for recognizer in [tap, secondaryTap, dragPan, twoFingerPan] { content.addGestureRecognizer(recognizer) }
    }

    func gestureRecognizer(
      _ gestureRecognizer: UIGestureRecognizer,
      shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer
    ) -> Bool {
      gestureRecognizer === twoFingerPan && other === scrollView.pinchGestureRecognizer
    }

    private func pointer(at location: CGPoint) -> ScreenSharingPointer? {
      let size = content.bounds.size
      guard size.width > 0, size.height > 0 else { return nil }
      let x = min(1, max(0, location.x / size.width))
      let y = min(1, max(0, location.y / size.height))
      return ScreenSharingPointer(x: x, y: y)
    }

    @objc private func tapped(_ recognizer: UITapGestureRecognizer) {
      let location = recognizer.location(in: content)
      guard let pointer = pointer(at: location) else { return }
      model.tap(at: pointer, location: recognizer.location(in: self), time: ProcessInfo.processInfo.systemUptime)
      ripple(at: location)
    }

    @objc private func secondaryTapped(_ recognizer: UITapGestureRecognizer) {
      let location = recognizer.location(in: content)
      guard let pointer = pointer(at: location) else { return }
      model.secondaryClick(at: pointer)
      ripple(at: location)
    }

    @objc private func dragged(_ recognizer: UIPanGestureRecognizer) {
      let finger = recognizer.location(in: self)
      switch recognizer.state {
      case .began:
        let translation = recognizer.translation(in: self)
        let origin = CGPoint(x: finger.x - translation.x, y: finger.y - translation.y)
        guard let start = pointer(at: content.convert(origin, from: self)) else { return }
        dragFinger = finger
        model.dragBegan(at: start)
        followFinger()
        startDragLink()
      case .changed:
        dragFinger = finger
        followFinger()
      case .ended, .cancelled, .failed:
        finishDrag(at: finger)
      default:
        break
      }
    }

    private func followFinger() {
      guard let finger = dragFinger, let pointer = pointer(at: content.convert(finger, from: self)) else { return }
      model.dragMoved(to: pointer)
    }

    private func finishDrag(at finger: CGPoint) {
      guard dragFinger != nil else { return }
      dragFinger = nil
      stopDragLink()
      if let pointer = pointer(at: content.convert(finger, from: self)) { model.dragEnded(at: pointer) }
    }

    private func cancelDrag() {
      guard let finger = dragFinger else { return }
      finishDrag(at: finger)
    }

    private func startDragLink() {
      dragLink?.invalidate()
      let link = CADisplayLink(target: self, selector: #selector(dragTick(_:)))
      link.add(to: .main, forMode: .common)
      dragLink = link
    }

    private func stopDragLink() {
      dragLink?.invalidate()
      dragLink = nil
    }

    @objc private func dragTick(_ link: CADisplayLink) {
      guard let finger = dragFinger else {
        stopDragLink()
        return
      }
      let step = ScreenSharingEdgeScroll.step(finger: finger, in: scrollView.frame)
      let inset = scrollView.contentInset
      let minimum = CGPoint(x: -inset.left, y: -inset.top)
      let maximum = CGPoint(
        x: max(minimum.x, scrollView.contentSize.width - scrollView.bounds.width + inset.right),
        y: max(minimum.y, scrollView.contentSize.height - scrollView.bounds.height + inset.bottom))
      let current = scrollView.contentOffset
      let next = CGPoint(
        x: min(maximum.x, max(minimum.x, current.x + step.dx)),
        y: min(maximum.y, max(minimum.y, current.y + step.dy)))
      if next != current { scrollView.contentOffset = next }
      followFinger()
    }

    @objc private func twoFingerPanned(_ recognizer: UIPanGestureRecognizer) {
      switch recognizer.state {
      case .began:
        scrollZoom = scrollView.zoomScale
        scrollTranslation = .zero
        scrollSuppressed = false
      case .changed:
        if abs(scrollView.zoomScale - scrollZoom) / scrollZoom > 0.03 { scrollSuppressed = true }
        guard !scrollSuppressed, let video = videoSize, content.bounds.width > 0 else { return }
        let translation = recognizer.translation(in: content)
        let ratio = video.width / content.bounds.width
        let dx = (translation.x - scrollTranslation.x) * ratio
        let dy = (translation.y - scrollTranslation.y) * ratio
        scrollTranslation = translation
        guard let pointer = pointer(at: recognizer.location(in: content)) else { return }
        model.scrolled(at: pointer, dx: dx, dy: dy)
      default:
        break
      }
    }

    private func ripple(at location: CGPoint) {
      let point = content.convert(location, to: self)
      let ring = CAShapeLayer()
      let radius: CGFloat = 22
      ring.path = UIBezierPath(ovalIn: CGRect(x: -radius, y: -radius, width: radius * 2, height: radius * 2)).cgPath
      ring.position = point
      ring.fillColor = UIColor.tintColor.withAlphaComponent(0.25).cgColor
      ring.strokeColor = UIColor.tintColor.withAlphaComponent(0.8).cgColor
      ring.lineWidth = 2
      layer.addSublayer(ring)
      let scale = CABasicAnimation(keyPath: "transform.scale")
      scale.fromValue = 0.4
      scale.toValue = 1
      let fade = CABasicAnimation(keyPath: "opacity")
      fade.fromValue = 1
      fade.toValue = 0
      let group = CAAnimationGroup()
      group.animations = [scale, fade]
      group.duration = 0.35
      group.timingFunction = CAMediaTimingFunction(name: .easeOut)
      ring.opacity = 0
      CATransaction.begin()
      CATransaction.setCompletionBlock { ring.removeFromSuperlayer() }
      ring.add(group, forKey: "ripple")
      CATransaction.commit()
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      let unhandled = ScreenSharingKeyInputView.forward(presses, to: model)
      if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }
  }
#endif
