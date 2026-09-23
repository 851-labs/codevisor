import SwiftUI
import UIKit

/// Keeps a presenting sheet's own drags (swipe to dismiss, the zoom
/// transition's interactive dismiss) from reacting to touches that begin
/// inside the composer card. The composer's drags scroll its text and
/// resize the card; the sheet should only follow drags that start outside it.
///
/// While a touch that began inside the card is down, the sheet's drag
/// recognizers are switched off and `onTouchingChange` reports it, so the
/// sheet can also disable interactive dismissal (see
/// `ComposerBlocksSheetDismissPreferenceKey`). Both are needed: a sheet
/// also dismisses by tracking the scroll view under the finger, and the
/// editor is a scroll view whose downward drag on an expanded card (which
/// collapses it) starts at its top edge. Disabling cancels the sheet's
/// recognizers outright rather than leaving them pending: UIKit makes a
/// scroll view at its top edge wait for the sheet's dismiss drag to fail,
/// so a failure dependency would deadlock the editor's own downward drag.
/// Touches elsewhere are ignored, so the sheet behaves normally everywhere
/// outside the card. Outside a sheet it does nothing.
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
    // The hosting controller joins its presentation after its views
    // reach the window; look for the sheet on the next turn.
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

  /// The drags UIKit attaches to the sheet's presentation: the sheet's own
  /// pan on its shadow view, and — for a zoom-transition sheet — the
  /// content swipe-to-dismiss and transform gestures on the presented root
  /// view. SwiftUI's own recognizers (bridged `UIKit…` types) and hover
  /// recognizers on that root view are content, and are left alone.
  private func presentingSheetDrags(of root: UIViewController) -> [UIGestureRecognizer] {
    guard let container = root.sheetPresentationController?.containerView else { return [] }
    var drags: [UIGestureRecognizer] = []
    var view: UIView? = root.view
    while let current = view {
      drags += (current.gestureRecognizers ?? []).filter(Self.isPresentationDrag)
      if current === container { break }
      view = current.superview
    }
    return drags
  }

  /// The root controller of the sheet presentation this view lives in.
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

/// Never recognizes. It only watches touch sequences: one that begins
/// inside the card calls `onBegin`, and `onEnd` once all its touches end.
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

/// True while a composer in a sheet needs the sheet to stay put: a touch
/// that began on the card is down, or the card is dragged fully open (its
/// editor then owns downward drags, which collapse it). The New Chat sheet
/// disables interactive dismissal while any composer reports it.
struct ComposerBlocksSheetDismissPreferenceKey: PreferenceKey {
  static let defaultValue = false

  static func reduce(value: inout Bool, nextValue: () -> Bool) {
    value = value || nextValue()
  }
}
