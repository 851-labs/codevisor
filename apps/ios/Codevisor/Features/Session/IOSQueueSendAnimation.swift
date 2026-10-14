import CodevisorCore
import CodevisorUI
import Observation
import SwiftUI
import UIKit

@MainActor @Observable
final class IOSQueueSendAnimation {
  private(set) var isFormingQueue = false
  private(set) var arrival = 0

  @ObservationIgnored private weak var target: IOSQueueSendTargetView?
  @ObservationIgnored private var proxy: IOSQueueSendProxy?
  @ObservationIgnored private var previousIDs: Set<String> = []
  @ObservationIgnored private var text = ""
  @ObservationIgnored private var acceptedID: String?
  @ObservationIgnored private var animator: UIViewPropertyAnimator?
  @ObservationIgnored private var watchdog: DispatchWorkItem?
  @ObservationIgnored private var startScheduled = false

  private static let watchdogDuration: TimeInterval = 0.71

  func stage(text: String, queue: [ServerPromptQueueItem], sourceFrame: CGRect, in window: UIWindow?) {
    cancel()
    guard let window, !sourceFrame.isEmpty, !UIAccessibility.isReduceMotionEnabled else { return }
    self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
    previousIDs = Set(queue.map(\.id))
    isFormingQueue = queue.isEmpty
    let proxy = IOSQueueSendProxy(text: self.text.isEmpty ? "Attachment" : self.text)
    proxy.frame = sourceFrame.insetBy(dx: -13, dy: -9)
    window.addSubview(proxy)
    proxy.layoutIfNeeded()
    self.proxy = proxy
    IOSNavigationDiagnostics.record("queueSend.stage", "first=\(isFormingQueue)")

    let watchdog = DispatchWorkItem { [weak self] in self?.cancel() }
    self.watchdog = watchdog
    DispatchQueue.main.asyncAfter(
      deadline: .now() + Self.watchdogDuration,
      execute: watchdog
    )
  }

  func queueDidChange(_ queue: [ServerPromptQueueItem]) {
    guard proxy != nil else { return }
    if let acceptedID {
      if !queue.contains(where: { $0.id == acceptedID }) { cancel() }
      return
    }
    guard let item = queue.first(where: { !previousIDs.contains($0.id) && $0.text == text }) else {
      return
    }
    acceptedID = item.id
    scheduleFlight()
  }

  func updateTarget(_ target: IOSQueueSendTargetView) {
    self.target = target
    scheduleFlight()
  }

  private func scheduleFlight() {
    guard proxy != nil, acceptedID != nil, animator == nil, !startScheduled else { return }
    startScheduled = true
    DispatchQueue.main.async { [weak self] in
      guard let self else { return }
      startScheduled = false
      beginFlight()
    }
  }

  private func beginFlight() {
    guard let proxy, let target, let window = target.window,
      proxy.window === window, acceptedID != nil, animator == nil,
      !target.bounds.isEmpty
    else { return }
    let queueFrame = target.convert(target.bounds, to: window)
    let formingQueue = isFormingQueue
    let destination: CGRect
    if formingQueue {
      destination = queueFrame
    } else {
      destination = CGRect(
        x: queueFrame.maxX - 50, y: queueFrame.midY - 18, width: 40, height: 36
      )
    }
    IOSNavigationDiagnostics.record(
      "queueSend.flight", "first=\(formingQueue) target=\(NSCoder.string(for: destination))"
    )
    let move = UIViewPropertyAnimator(duration: 0.46, dampingRatio: 0.88)
    animator = move
    move.addAnimations {
      proxy.frame = destination
      proxy.land(formingQueue: formingQueue)
      proxy.layoutIfNeeded()
    }
    move.addCompletion { [weak self, weak proxy] position in
      guard let self, let proxy, self.proxy === proxy, position == .end else { return }
      var transaction = Transaction()
      transaction.disablesAnimations = true
      withTransaction(transaction) { self.isFormingQueue = false }
      if !formingQueue { self.arrival &+= 1 }
      let dissolve = UIViewPropertyAnimator(duration: 0.14, curve: .easeOut) {
        proxy.alpha = 0
      }
      self.animator = dissolve
      dissolve.addCompletion { [weak self, weak proxy] _ in
        guard let self, self.proxy === proxy else { return }
        IOSNavigationDiagnostics.record("queueSend.complete")
        self.cancel()
      }
      dissolve.startAnimation()
    }
    move.startAnimation()
    proxy.transitionContent(formingQueue: formingQueue)
  }

  func cancel() {
    watchdog?.cancel()
    watchdog = nil
    if animator?.state == .active { animator?.stopAnimation(true) }
    animator = nil
    proxy?.removeFromSuperview()
    proxy = nil
    acceptedID = nil
    previousIDs = []
    isFormingQueue = false
  }
}

struct IOSQueueSendTarget: UIViewRepresentable {
  let animation: IOSQueueSendAnimation

  func makeUIView(context: Context) -> IOSQueueSendTargetView {
    IOSQueueSendTargetView(animation: animation)
  }

  func updateUIView(_ view: IOSQueueSendTargetView, context: Context) {
    view.animation = animation
    animation.updateTarget(view)
  }
}

final class IOSQueueSendTargetView: UIView {
  weak var animation: IOSQueueSendAnimation?

  init(animation: IOSQueueSendAnimation) {
    self.animation = animation
    super.init(frame: .zero)
    isUserInteractionEnabled = false
    accessibilityElementsHidden = true
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func layoutSubviews() {
    super.layoutSubviews()
    animation?.updateTarget(self)
  }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    if window != nil { animation?.updateTarget(self) }
  }
}

extension UIWindow {
  static var codevisorKeyWindow: UIWindow? {
    let scenes = UIApplication.shared.connectedScenes
      .compactMap { $0 as? UIWindowScene }
      .filter { $0.activationState == .foregroundActive }
    return scenes.lazy.flatMap(\.windows).first(where: \.isKeyWindow)
      ?? scenes.first?.keyWindow
  }
}
