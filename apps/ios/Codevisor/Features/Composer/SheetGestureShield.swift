import SwiftUI
import UIKit

struct SheetGestureShield: UIViewRepresentable {
  var onTouchingChange: (Bool) -> Void = { _ in }

  func makeUIView(context _: Context) -> SheetGestureShieldView {
    SheetGestureShieldView()
  }

  func updateUIView(_ view: SheetGestureShieldView, context _: Context) {
    view.onTouchingChange = onTouchingChange
  }

  static func dismantleUIView(_ view: SheetGestureShieldView, coordinator _: ()) {
    view.uninstall()
  }
}

final class SheetGestureShieldView: UIView, UIGestureRecognizerDelegate {
  private lazy var suppressor: SheetDragSuppressor = {
    let recognizer = SheetDragSuppressor()
    recognizer.delegate = self
    recognizer.beginsInside = { [weak self] touch in
      guard let self, self.window != nil else { return false }
      return self.bounds.contains(touch.location(in: self))
    }
    recognizer.onBegin = { [weak self] in self?.suppressSheet() }
    recognizer.onEnd = { [weak self] in self?.restoreSheet() }
    return recognizer
  }()

  var onTouchingChange: (Bool) -> Void = { _ in }
  private var suppressedDrags: [UIGestureRecognizer] = []
  private var isReportingTouch = false

  private func suppressSheet() {
    guard let root = presentedRoot() else { return }
    suppressedDrags = presentingSheetDrags(of: root).filter(\.isEnabled)
    for recognizer in suppressedDrags {
      recognizer.isEnabled = false
    }
    isReportingTouch = true
    onTouchingChange(true)
  }

  private func restoreSheet() {
    for recognizer in suppressedDrags {
      recognizer.isEnabled = true
    }
    suppressedDrags = []
    guard isReportingTouch else { return }
    isReportingTouch = false
    onTouchingChange(false)
  }

  override init(frame: CGRect) {
    super.init(frame: frame)
    backgroundColor = .clear
    isUserInteractionEnabled = false
    isAccessibilityElement = false
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    uninstall()
    guard let window else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window === window, self.suppressor.view == nil,
        self.presentedRoot() != nil
      else { return }
      window.addGestureRecognizer(self.suppressor)
    }
  }

  func uninstall() {
    suppressor.view?.removeGestureRecognizer(suppressor)
    restoreSheet()
  }

  private func presentingSheetDrags(of root: UIViewController) -> [UIGestureRecognizer] {
    guard let container = root.sheetPresentationController?.containerView else { return [] }
    var drags: [UIGestureRecognizer] = []
    var view: UIView? = root.view
    while let current = view {
      drags += (current.gestureRecognizers ?? []).filter { Self.isPresentationDrag($0) }
      if current === container { break }
      view = current.superview
    }
    return drags
  }

  private func presentedRoot() -> UIViewController? {
    var responder: UIResponder? = self
    var controller: UIViewController?
    while let current = responder {
      if let found = current as? UIViewController {
        controller = found
        break
      }
      responder = current.next
    }
    guard var root = controller else { return nil }
    while let parent = root.parent {
      root = parent
    }
    return root.sheetPresentationController?.containerView == nil ? nil : root
  }

  private static func isPresentationDrag(_ recognizer: UIGestureRecognizer) -> Bool {
    guard !(recognizer is UIHoverGestureRecognizer),
      !(recognizer is SheetDragSuppressor)
    else { return false }
    return !String(describing: type(of: recognizer)).hasPrefix("UIKit")
  }

  func gestureRecognizer(
    _: UIGestureRecognizer,
    shouldRecognizeSimultaneouslyWith _: UIGestureRecognizer
  ) -> Bool {
    true
  }
}

final class SheetDragSuppressor: UIGestureRecognizer {
  var beginsInside: (UITouch) -> Bool = { _ in false }
  var onBegin: () -> Void = {}
  var onEnd: () -> Void = {}
  private var isSuppressing = false

  override init(target: Any?, action: Selector?) {
    super.init(target: target, action: action)
    cancelsTouchesInView = false
    delaysTouchesBegan = false
    delaysTouchesEnded = false
  }

  convenience init() {
    self.init(target: nil, action: nil)
  }

  override func touchesBegan(_ touches: Set<UITouch>, with _: UIEvent) {
    guard !isSuppressing else { return }
    guard touches.contains(where: beginsInside) else {
      state = .failed
      return
    }
    isSuppressing = true
    onBegin()
  }

  override func touchesEnded(_: Set<UITouch>, with event: UIEvent) {
    finishIfAllTouchesEnded(event)
  }

  override func touchesCancelled(_: Set<UITouch>, with event: UIEvent) {
    finishIfAllTouchesEnded(event)
  }

  private func finishIfAllTouchesEnded(_ event: UIEvent) {
    let active = (event.allTouches ?? []).contains { touch in
      touch.phase != .ended && touch.phase != .cancelled
    }
    if !active {
      state = .failed
    }
  }

  override func reset() {
    super.reset()
    guard isSuppressing else { return }
    isSuppressing = false
    onEnd()
  }
}

struct ComposerBlocksSheetDismissPreferenceKey: PreferenceKey {
  static let defaultValue = false

  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}
