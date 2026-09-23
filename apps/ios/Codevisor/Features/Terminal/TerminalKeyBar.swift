import Combine
import SwiftTerm
import SwiftUI
import UIKit

/// Bridges the SwiftUI key bar to the SwiftTerm terminal view: key sends,
/// ctrl/touch modifier state, and the keyboard's geometry.
///
/// The pane is laid out edge to edge and opts out of SwiftUI's own keyboard
/// avoidance (see `EdgeToEdgePaneHost`), so the keyboard is measured here
/// instead: where its top edge lands, and the curve it travels on, so the
/// terminal and the key bar move with it rather than racing it.
@MainActor
final class TerminalKeyController: ObservableObject {
  private(set) weak var terminalView: SwiftTerm.TerminalView?

  @Published private(set) var keyboardVisible = false
  /// The docked keyboard's top edge in the host window's coordinate space —
  /// the space SwiftUI reports as `.global`, so a pane can subtract its own
  /// bottom edge from this to learn how much of it the keyboard covers.
  ///
  /// `nil` while the keyboard is down, and while it is floating or split:
  /// those don't reach the window's bottom edge, so they cover nothing the
  /// terminal has to stay clear of.
  @Published private(set) var keyboardTop: CGFloat?
  @Published var ctrlActive = false
  @Published var touchModeActive = false

  private var observers: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    // willChangeFrame rather than willShow: it also reports the keyboard
    // growing, shrinking and undocking while it is already up.
    observers.append(
      center.addObserver(
        forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
      ) { [weak self] note in
        MainActor.assumeIsolated { self?.keyboardWillChangeFrame(note) }
      })
    observers.append(
      center.addObserver(
        forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
      ) { [weak self] note in
        MainActor.assumeIsolated { self?.apply(top: nil, visible: false, note: note) }
      })
    // SwiftTerm auto-clears the control modifier after applying it to the
    // next keystroke; mirror that in the button state.
    observers.append(
      center.addObserver(
        forName: .terminalViewControlModifierReset, object: nil, queue: .main
      ) { [weak self] _ in
        Task { @MainActor in self?.ctrlActive = false }
      })
  }

  // MARK: - Keyboard geometry

  private func keyboardWillChangeFrame(_ note: Notification) {
    guard
      let end = (note.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue,
      let window = terminalView?.window
    else { return }
    // The notification carries screen coordinates. Converting through the
    // window is what keeps this right in Split View, Slide Over and Stage
    // Manager, where the window is only part of the screen.
    let frame = window.convert(end, from: window.screen.coordinateSpace)
    let bounds = window.bounds
    let isDocked = frame.maxY >= bounds.maxY - 1 && frame.width >= bounds.width - 1
    apply(top: isDocked ? frame.minY : nil, visible: frame.minY < bounds.maxY, note: note)
  }

  private func apply(top: CGFloat?, visible: Bool, note: Notification) {
    guard top != keyboardTop || visible != keyboardVisible else { return }
    withAnimation(Self.animation(for: note)) {
      keyboardTop = top
      keyboardVisible = visible
    }
  }

  /// The keyboard's own duration and curve. UIKit reports a private curve
  /// (raw value 7) for the keyboard itself, which has no SwiftUI equivalent;
  /// its control points are approximated here. Anything else is a curve
  /// SwiftUI names.
  private static func animation(for note: Notification) -> Animation {
    let info = note.userInfo
    let duration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    guard duration > 0 else { return .linear(duration: 0) }
    switch info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int {
    case UIView.AnimationCurve.easeInOut.rawValue: return .easeInOut(duration: duration)
    case UIView.AnimationCurve.easeIn.rawValue: return .easeIn(duration: duration)
    case UIView.AnimationCurve.easeOut.rawValue: return .easeOut(duration: duration)
    case UIView.AnimationCurve.linear.rawValue: return .linear(duration: duration)
    default: return .timingCurve(0.17, 0.17, 0, 1, duration: duration)
    }
  }

  deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func attach(_ view: SwiftTerm.TerminalView) {
    terminalView = view
  }

  func showKeyboard() {
    _ = terminalView?.becomeFirstResponder()
  }

  func toggleKeyboard() {
    if keyboardVisible {
      _ = terminalView?.resignFirstResponder()
    } else {
      showKeyboard()
    }
  }

  func sendEsc() { clickAndSend(EscapeSequences.cmdEsc) }
  func sendTab() { clickAndSend(EscapeSequences.cmdTab) }

  enum Arrow {
    case up, down, left, right
  }

  func sendArrow(_ arrow: Arrow) {
    guard let tv = terminalView else { return }
    let app = tv.getTerminal().applicationCursor
    let data: [UInt8] =
      switch arrow {
      case .up: app ? EscapeSequences.moveUpApp : EscapeSequences.moveUpNormal
      case .down: app ? EscapeSequences.moveDownApp : EscapeSequences.moveDownNormal
      case .left: app ? EscapeSequences.moveLeftApp : EscapeSequences.moveLeftNormal
      case .right: app ? EscapeSequences.moveRightApp : EscapeSequences.moveRightNormal
      }
    clickAndSend(data)
  }

  func toggleCtrl() {
    guard let tv = terminalView else { return }
    UIDevice.current.playInputClick()
    // With no TerminalAccessory installed, SwiftTerm falls back to the
    // TerminalView's own controlModifier and auto-clears it after use.
    tv.controlModifier.toggle()
    ctrlActive = tv.controlModifier
  }

  func toggleTouchMode() {
    guard let tv = terminalView else { return }
    UIDevice.current.playInputClick()
    tv.allowMouseReporting.toggle()
    touchModeActive = !tv.allowMouseReporting
  }

  private func clickAndSend(_ data: [UInt8]) {
    UIDevice.current.playInputClick()
    terminalView?.send(data)
  }
}

/// Liquid Glass key bar floating above the keyboard: esc, ctrl, tab, arrows,
/// and touch-mode toggle. Shown only while the keyboard is up; the keyboard is
/// dismissed by swiping it down (interactive dismissal on the terminal).
struct TerminalKeyBar: View {
  @ObservedObject var controller: TerminalKeyController

  var body: some View {
    HStack(spacing: 0) {
      key("escape", "Escape") { controller.sendEsc() }
      toggleKey("control", "Control", isOn: controller.ctrlActive) { controller.toggleCtrl() }
      key("arrow.right.to.line.compact", "Tab") { controller.sendTab() }
      repeatKey("arrow.left", "Left arrow", .left)
      repeatKey("arrow.down", "Down arrow", .down)
      repeatKey("arrow.up", "Up arrow", .up)
      repeatKey("arrow.right", "Right arrow", .right)
      toggleKey("hand.draw", "Touch mode", isOn: controller.touchModeActive) {
        controller.toggleTouchMode()
      }
    }
    .padding(.horizontal, 10)
    .frame(height: 48)
    .glassEffect(.regular.interactive(), in: .capsule)
  }

  private func key(_ icon: String, _ label: String, action: @escaping () -> Void) -> some View {
    Button(action: action) {
      keyLabel(icon)
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
  }

  private func toggleKey(
    _ icon: String, _ label: String, isOn: Bool, action: @escaping () -> Void
  ) -> some View {
    Button(action: action) {
      keyLabel(icon)
        .foregroundStyle(isOn ? AnyShapeStyle(.background) : AnyShapeStyle(.primary))
        .background {
          if isOn {
            Circle().fill(.primary).frame(width: 32, height: 32)
          }
        }
    }
    .buttonStyle(.plain)
    .accessibilityLabel(label)
    .accessibilityAddTraits(isOn ? .isSelected : [])
  }

  private func repeatKey(
    _ icon: String, _ label: String, _ arrow: TerminalKeyController.Arrow
  )
    -> some View
  {
    RepeatKeyButton(icon: icon, label: label) { controller.sendArrow(arrow) }
  }

  private func keyLabel(_ icon: String) -> some View {
    Image(systemName: icon)
      .font(.system(size: 16, weight: .medium))
      .frame(maxWidth: .infinity)
      .frame(height: 48)
      .contentShape(Rectangle())
  }
}

/// A key that fires on touch-down and auto-repeats while held
/// (600ms delay, then every 100ms) — used for the arrow keys.
private struct RepeatKeyButton: View {
  let icon: String
  let label: String
  let action: () -> Void

  @State private var repeatTask: Task<Void, Never>?

  var body: some View {
    Image(systemName: icon)
      .font(.system(size: 16, weight: .medium))
      .frame(maxWidth: .infinity)
      .frame(height: 48)
      .contentShape(Rectangle())
      .opacity(repeatTask == nil ? 1 : 0.4)
      .gesture(
        DragGesture(minimumDistance: 0)
          .onChanged { _ in startIfNeeded() }
          .onEnded { _ in stop() }
      )
      .accessibilityLabel(label)
      .accessibilityAddTraits(.isButton)
  }

  private func startIfNeeded() {
    guard repeatTask == nil else { return }
    action()
    repeatTask = Task {
      try? await Task.sleep(nanoseconds: 600_000_000)
      while !Task.isCancelled {
        action()
        try? await Task.sleep(nanoseconds: 100_000_000)
      }
    }
  }

  private func stop() {
    repeatTask?.cancel()
    repeatTask = nil
  }
}

/// Liquid Glass circular button shown while the keyboard is hidden;
/// tapping it brings the keyboard back.
struct ShowKeyboardButton: View {
  let action: () -> Void

  var body: some View {
    Button(action: action) {
      Image(systemName: "keyboard")
        .font(.system(size: 17, weight: .medium))
        .frame(width: 48, height: 48)
        .contentShape(Circle())
    }
    .buttonStyle(.plain)
    .glassEffect(.regular.interactive(), in: .circle)
    .accessibilityLabel("Show keyboard")
  }
}
