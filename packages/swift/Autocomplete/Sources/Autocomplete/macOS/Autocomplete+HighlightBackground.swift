#if canImport(AppKit)
  import AppKit
  import SwiftUI

  extension Autocomplete {
    /// The highlight behind a hovered or keyboard-focused item.
    struct HighlightBackground: View {
      let highlight: ItemHighlight
      let topCornerRadius: CGFloat
      let bottomCornerRadius: CGFloat

      var body: some View {
        switch highlight {
        case .menuSelection:
          NativeMenuSelectionMaterial()
            // AppKit applies this small color transform when `.selection` is
            // hosted by an NSMenu. Reproduce it in a SwiftUI popover while
            // retaining the material's accent and appearance behavior.
            .brightness(0.0274)
            .saturation(1.0126)
            .hueRotation(.degrees(-1.30))
            .clipShape(shape)
        case let .fill(color, _):
          shape.fill(color)
        }
      }

      private var shape: UnevenRoundedRectangle {
        UnevenRoundedRectangle(
          topLeadingRadius: topCornerRadius,
          bottomLeadingRadius: bottomCornerRadius,
          bottomTrailingRadius: bottomCornerRadius,
          topTrailingRadius: topCornerRadius,
          style: .continuous
        )
      }
    }

    struct NativeMenuSelectionMaterial: NSViewRepresentable {
      func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        configure(view)
        return view
      }

      func updateNSView(_ view: NSVisualEffectView, context: Context) {
        configure(view)
      }

      private func configure(_ view: NSVisualEffectView) {
        view.material = .selection
        view.blendingMode = .withinWindow
        view.state = .active
        view.isEmphasized = true
        view.setAccessibilityElement(false)
      }
    }
  }

  extension Autocomplete {
    /// "⌘N", "⇧⌘[", "⌃⌥⌘←" — modifiers in the order the menu bar uses.
    public static func symbols(for shortcut: KeyboardShortcut) -> String {
      var text = ""
      let modifiers = shortcut.modifiers
      if modifiers.contains(.control) { text += "⌃" }
      if modifiers.contains(.option) { text += "⌥" }
      if modifiers.contains(.shift) { text += "⇧" }
      if modifiers.contains(.command) { text += "⌘" }
      return text + keySymbol(for: shortcut.key)
    }

    public static func accessibilityDescription(for shortcut: KeyboardShortcut) -> String {
      var parts: [String] = []
      let modifiers = shortcut.modifiers
      if modifiers.contains(.control) { parts.append(Strings.text("Control")) }
      if modifiers.contains(.option) { parts.append(Strings.text("Option")) }
      if modifiers.contains(.shift) { parts.append(Strings.text("Shift")) }
      if modifiers.contains(.command) { parts.append(Strings.text("Command")) }
      parts.append(keyDescription(for: shortcut.key))
      return parts.joined(separator: " ")
    }

    private static func keyDescription(for key: KeyEquivalent) -> String {
      switch key {
      case .return: Strings.text("Return")
      case .delete: Strings.text("Delete")
      case .deleteForward: Strings.text("Forward Delete")
      case .escape: Strings.text("Escape")
      case .tab: Strings.text("Tab")
      case .space: Strings.text("Space")
      case .upArrow: Strings.text("Up Arrow")
      case .downArrow: Strings.text("Down Arrow")
      case .leftArrow: Strings.text("Left Arrow")
      case .rightArrow: Strings.text("Right Arrow")
      case .home: Strings.text("Home")
      case .end: Strings.text("End")
      case .pageUp: Strings.text("Page Up")
      case .pageDown: Strings.text("Page Down")
      case .clear: Strings.text("Clear")
      default: String(key.character).uppercased()
      }
    }

    private static func keySymbol(for key: KeyEquivalent) -> String {
      switch key {
      case .return: "↩"
      case .delete: "⌫"
      case .deleteForward: "⌦"
      case .escape: "⎋"
      case .tab: "⇥"
      case .space: "␣"
      case .upArrow: "↑"
      case .downArrow: "↓"
      case .leftArrow: "←"
      case .rightArrow: "→"
      case .home: "↖"
      case .end: "↘"
      case .pageUp: "⇞"
      case .pageDown: "⇟"
      case .clear: "⌧"
      default: String(key.character).uppercased()
      }
    }
  }
#endif
