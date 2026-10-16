#if os(iOS)
  import SwiftUI
  import UIKit

  final class ScreenSharingKeyInputView: UIView, UIKeyInput {
    private let model: ScreenSharingPaneModel
    private lazy var bar: UIInputView = {
      let bar = UIInputView(frame: CGRect(x: 0, y: 0, width: 0, height: 48), inputViewStyle: .keyboard)
      bar.allowsSelfSizing = true
      let host = UIHostingController(rootView: ScreenSharingKeyBar(model: model))
      host.view.backgroundColor = .clear
      host.view.translatesAutoresizingMaskIntoConstraints = false
      bar.addSubview(host.view)
      NSLayoutConstraint.activate([
        host.view.leadingAnchor.constraint(equalTo: bar.leadingAnchor),
        host.view.trailingAnchor.constraint(equalTo: bar.trailingAnchor),
        host.view.topAnchor.constraint(equalTo: bar.topAnchor),
        host.view.bottomAnchor.constraint(equalTo: bar.bottomAnchor),
        host.view.heightAnchor.constraint(equalToConstant: 48),
      ])
      return bar
    }()

    init(model: ScreenSharingPaneModel) {
      self.model = model
      super.init(frame: .zero)
      isAccessibilityElement = false
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var canBecomeFirstResponder: Bool { true }
    override var inputAccessoryView: UIView? { bar }

    var autocorrectionType: UITextAutocorrectionType = .no
    var autocapitalizationType: UITextAutocapitalizationType = .none
    var spellCheckingType: UITextSpellCheckingType = .no
    var smartQuotesType: UITextSmartQuotesType = .no
    var smartDashesType: UITextSmartDashesType = .no
    var smartInsertDeleteType: UITextSmartInsertDeleteType = .no
    var inlinePredictionType: UITextInlinePredictionType = .no
    var keyboardType: UIKeyboardType = .default
    var returnKeyType: UIReturnKeyType = .default

    var hasText: Bool { true }

    func insertText(_ text: String) {
      if text == "\n" {
        model.press(.returnKey)
      } else {
        model.type(text)
      }
    }

    func deleteBackward() { model.press(.delete) }

    override func resignFirstResponder() -> Bool {
      let resigned = super.resignFirstResponder()
      if resigned, model.keyboardShown { model.keyboardShown = false }
      return resigned
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
      let unhandled = Self.forward(presses, to: model)
      if !unhandled.isEmpty { super.pressesBegan(unhandled, with: event) }
    }

    @MainActor
    static func forward(_ presses: Set<UIPress>, to model: ScreenSharingPaneModel) -> Set<UIPress> {
      presses.filter { press in
        guard let key = press.key else { return true }
        var modifiers: ScreenSharingModifiers = []
        if key.modifierFlags.contains(.shift) { modifiers.insert(.shift) }
        if key.modifierFlags.contains(.control) { modifiers.insert(.control) }
        if key.modifierFlags.contains(.alternate) { modifiers.insert(.option) }
        if key.modifierFlags.contains(.command) { modifiers.insert(.command) }
        return !model.pressHardwareKey(usage: key.keyCode.rawValue, modifiers: modifiers)
      }
    }
  }

  struct ScreenSharingKeyBar: View {
    let model: ScreenSharingPaneModel

    var body: some View {
      HStack(spacing: 6) {
        ScrollView(.horizontal) {
          HStack(spacing: 6) {
            key("esc") { model.press(.escape) }
            key(systemImage: "arrow.right.to.line", label: "Tab") { model.press(.tab) }
            modifier(.control, symbol: "control", label: "Control")
            modifier(.option, symbol: "option", label: "Option")
            modifier(.shift, symbol: "shift", label: "Shift")
            modifier(.command, symbol: "command", label: "Command")
            key(systemImage: "arrow.left", label: "Left Arrow") { model.press(.left) }
            key(systemImage: "arrow.up", label: "Up Arrow") { model.press(.up) }
            key(systemImage: "arrow.down", label: "Down Arrow") { model.press(.down) }
            key(systemImage: "arrow.right", label: "Right Arrow") { model.press(.right) }
          }
          .padding(.horizontal, 8)
        }
        .scrollIndicators(.hidden)
        Button {
          model.keyboardShown = false
        } label: {
          Image(systemName: "keyboard.chevron.compact.down")
            .frame(width: 40, height: 36)
        }
        .accessibilityLabel("Hide Keyboard")
        .padding(.trailing, 8)
      }
      .frame(height: 48)
      .buttonStyle(.plain)
      .font(.system(size: 15, weight: .medium))
    }

    private func key(_ title: String, action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Text(title).frame(minWidth: 40, minHeight: 36).padding(.horizontal, 4)
      }
      .background(.background.secondary, in: .rect(cornerRadius: 8))
    }

    private func key(systemImage: String, label: String, action: @escaping () -> Void) -> some View {
      Button(action: action) {
        Image(systemName: systemImage).frame(width: 40, height: 36)
      }
      .background(.background.secondary, in: .rect(cornerRadius: 8))
      .accessibilityLabel(label)
    }

    private func modifier(_ modifier: ScreenSharingModifiers, symbol: String, label: String) -> some View {
      let active = model.modifiers.contains(modifier)
      return Button {
        model.toggle(modifier)
      } label: {
        Image(systemName: symbol).frame(width: 40, height: 36)
          .foregroundStyle(active ? Color.white : Color.primary)
      }
      .background(active ? AnyShapeStyle(.tint) : AnyShapeStyle(.background.secondary), in: .rect(cornerRadius: 8))
      .accessibilityLabel(label)
      .accessibilityAddTraits(active ? .isSelected : [])
    }
  }
#endif
