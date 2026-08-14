import Combine
import SwiftTerm
import SwiftUI
import UIKit

/// Bridges the SwiftUI key bar to the SwiftTerm terminal view: key sends,
/// ctrl/touch modifier state, and keyboard visibility tracking.
@MainActor
final class TerminalKeyController: ObservableObject {
    private(set) weak var terminalView: SwiftTerm.TerminalView?

    @Published var keyboardVisible = false
    @Published var ctrlActive = false
    @Published var touchModeActive = false

    private var observers: [NSObjectProtocol] = []

    init() {
        let center = NotificationCenter.default
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillShowNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.keyboardVisible = true }
            })
        observers.append(
            center.addObserver(
                forName: UIResponder.keyboardWillHideNotification, object: nil, queue: .main
            ) { [weak self] _ in
                Task { @MainActor in self?.keyboardVisible = false }
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
