import Combine
import GhosttyTerminal
import SwiftUI
import UIKit

@MainActor
final class TerminalKeyController: ObservableObject {
  private(set) weak var terminalView: SessionTerminalView?

  @Published private(set) var keyboardVisible = false
  @Published private(set) var keyboardTop: CGFloat?
  @Published var ctrlActive = false

  private var observers: [NSObjectProtocol] = []

  init() {
    let center = NotificationCenter.default
    observers.append(
      center.addObserver(
        forName: UIResponder.keyboardWillChangeFrameNotification, object: nil, queue: .main
      ) { [weak self] note in
        let change = KeyboardChange(note)
        MainActor.assumeIsolated { self?.keyboardWillChangeFrame(change) }
      })
    observers.append(
      center.addObserver(
        forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
      ) { [weak self] note in
        let change = KeyboardChange(note)
        MainActor.assumeIsolated { self?.apply(top: nil, visible: false, change: change) }
      })
  }

  private func keyboardWillChangeFrame(_ change: KeyboardChange) {
    guard
      let end = change.endFrame,
      let window = terminalView?.window
    else { return }
    let frame = window.convert(end, from: window.screen.coordinateSpace)
    let bounds = window.bounds
    let isDocked = frame.maxY >= bounds.maxY - 1 && frame.width >= bounds.width - 1
    apply(top: isDocked ? frame.minY : nil, visible: frame.minY < bounds.maxY, change: change)
  }

  private func apply(top: CGFloat?, visible: Bool, change: KeyboardChange) {
    guard top != keyboardTop || visible != keyboardVisible else { return }
    withAnimation(Self.animation(for: change)) {
      keyboardTop = top
      keyboardVisible = visible
    }
  }

  private static func animation(for change: KeyboardChange) -> Animation {
    let duration = change.duration
    guard duration > 0 else { return .linear(duration: 0) }
    switch change.curve {
    case UIView.AnimationCurve.easeInOut.rawValue: return .easeInOut(duration: duration)
    case UIView.AnimationCurve.easeIn.rawValue: return .easeIn(duration: duration)
    case UIView.AnimationCurve.easeOut.rawValue: return .easeOut(duration: duration)
    case UIView.AnimationCurve.linear.rawValue: return .linear(duration: duration)
    default: return .timingCurve(0.17, 0.17, 0, 1, duration: duration)
    }
  }

  isolated deinit {
    for observer in observers {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  func attach(_ view: SessionTerminalView) {
    guard terminalView !== view else { return }
    terminalView = view
    view.setStickyModifierChangeHandler { [weak self, weak view] in
      guard let view else { return }
      self?.ctrlActive = view.stickyActivation(for: .ctrl) != .inactive
    }
    ctrlActive = view.stickyActivation(for: .ctrl) != .inactive
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

  func sendEsc() { press(.escape) }
  func sendTab() { press(.tab) }

  enum Arrow {
    case up, down, left, right
  }

  func sendArrow(_ arrow: Arrow) {
    switch arrow {
    case .up: press(.arrowUp)
    case .down: press(.arrowDown)
    case .left: press(.arrowLeft)
    case .right: press(.arrowRight)
    }
  }

  func toggleCtrl() {
    guard let terminalView else { return }
    UIDevice.current.playInputClick()
    terminalView.toggleStickyModifier(.ctrl)
    ctrlActive = terminalView.stickyActivation(for: .ctrl) != .inactive
  }

  private func press(_ key: TerminalKey) {
    UIDevice.current.playInputClick()
    terminalView?.noteUserInput()
    _ = terminalView?.sendKey(key)
  }
}

nonisolated private struct KeyboardChange: Sendable {
  let endFrame: CGRect?
  let duration: Double
  let curve: Int?

  init(_ note: Notification) {
    let info = note.userInfo
    endFrame = (info?[UIResponder.keyboardFrameEndUserInfoKey] as? NSValue)?.cgRectValue
    duration = info?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
    curve = info?[UIResponder.keyboardAnimationCurveUserInfoKey] as? Int
  }
}

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
