import SwiftUI
import AppKit

enum QuestionPickerKey: Equatable {
  case up
  case down
  case left
  case right
  case space
  case enter
  case escape
  case digit(Int)
}

struct QuestionPickerFocusAnchor: NSViewRepresentable {
  var onAttach: (QuestionPickerKeyView) -> Void
  var onKey: (QuestionPickerKey) -> Bool
  var onDetach: (QuestionPickerKeyView) -> Void

  func makeNSView(context: Context) -> QuestionPickerKeyView {
    let view = QuestionPickerKeyView()
    view.onAttach = onAttach
    view.onKey = onKey
    view.onDetach = onDetach
    return view
  }

  func updateNSView(_ view: QuestionPickerKeyView, context: Context) {
    view.onAttach = onAttach
    view.onKey = onKey
    view.onDetach = onDetach
  }
}

final class QuestionPickerKeyView: NSView {
  var onAttach: ((QuestionPickerKeyView) -> Void)?
  var onKey: ((QuestionPickerKey) -> Bool)?
  var onDetach: ((QuestionPickerKeyView) -> Void)?

  override var acceptsFirstResponder: Bool { true }

  override func hitTest(_ point: NSPoint) -> NSView? { nil }

  override func viewWillMove(toWindow newWindow: NSWindow?) {
    super.viewWillMove(toWindow: newWindow)
    if newWindow == nil { onDetach?(self) }
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    guard window != nil else { return }
    DispatchQueue.main.async { [weak self] in
      guard let self, self.window != nil else { return }
      self.onAttach?(self)
    }
  }

  override func keyDown(with event: NSEvent) {
    if let key = Self.semanticKey(for: event), onKey?(key) == true {
      return
    }
    let mods = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.numericPad])
    if mods.isEmpty, event.charactersIgnoringModifiers?.isEmpty == false {
      return
    }
    super.keyDown(with: event)
  }

  private static func semanticKey(for event: NSEvent) -> QuestionPickerKey? {
    let mods = event.modifierFlags
      .intersection(.deviceIndependentFlagsMask)
      .subtracting([.function, .numericPad])
    guard mods.isEmpty else { return nil }
    switch event.specialKey {
    case .upArrow: return .up
    case .downArrow: return .down
    case .leftArrow: return .left
    case .rightArrow: return .right
    default: break
    }
    switch event.keyCode {
    case 36, 76: return .enter
    case 53: return .escape
    default: break
    }
    guard let characters = event.charactersIgnoringModifiers else { return nil }
    if characters == " " { return .space }
    if characters.count == 1,
      let digit = characters.first?.wholeNumberValue,
      (1...9).contains(digit)
    {
      return .digit(digit)
    }
    return nil
  }
}
