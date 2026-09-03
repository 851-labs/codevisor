#if canImport(AppKit)
  import AppKit
  import SwiftUI

  public extension Autocomplete {
    /// What an item's content needs to know to draw itself.
    struct ItemContext: Sendable, Hashable {
      public let isHighlighted: Bool
      public let isHovering: Bool
      public let isDisabled: Bool
    }

    /// A named action exposed to assistive technology on an item, standing in
    /// for a hover-only accessory control (e.g. "Add to Favorites").
    struct ItemAction {
      public let name: String
      public let perform: () -> Void

      public init(name: String, perform: @escaping () -> Void) {
        self.name = name
        self.perform = perform
      }
    }

    /// One selectable row on the menu grid: fixed height, highlight
    /// background, hover reporting, keyboard acceptance, and an optional
    /// trailing accessory that sits outside the row's button so it can be a
    /// control of its own.
    struct Item<ID: Hashable, Icon: View, Label: View, Accessory: View>: View {
      let id: ID
      let icon: Icon?
      let shortcut: KeyboardShortcut?
      let isSelected: Bool
      let isDisabled: Bool
      let accessibilityAction: ItemAction?
      let action: () -> Void
      let label: (ItemContext) -> Label
      let accessory: ((ItemContext) -> Accessory)?

      @Environment(\.autocompleteStyle) private var style
      @Environment(Host.self) private var host
      @Environment(Highlight<ID>.self) private var highlight
      @State private var isHovering = false

      /// - Parameters:
      ///   - shortcut: The key equivalent shown dimmed at the trailing edge —
      ///     the same value the host binds with `keyboardShortcut`.
      ///   - icon: A leading glyph in a fixed slot, so titles align whether
      ///     or not every row has one. Any view; see the `Image` overloads
      ///     for the common case.
      public init(
        id: ID,
        shortcut: KeyboardShortcut? = nil,
        isSelected: Bool = false,
        isDisabled: Bool = false,
        accessibilityAction: ItemAction? = nil,
        action: @escaping () -> Void,
        @ViewBuilder icon: () -> Icon,
        @ViewBuilder label: @escaping (ItemContext) -> Label,
        @ViewBuilder accessory: @escaping (ItemContext) -> Accessory
      ) {
        self.id = id
        self.icon = icon()
        self.shortcut = shortcut
        self.isSelected = isSelected
        self.isDisabled = isDisabled
        self.accessibilityAction = accessibilityAction
        self.action = action
        self.label = label
        self.accessory = accessory
      }

      /// "⌘N", "⇧⌘[", "⌃⌥⌘←" — modifiers in the order the menu bar uses.
      static func symbols(for shortcut: KeyboardShortcut) -> String {
        var text = ""
        let modifiers = shortcut.modifiers
        if modifiers.contains(.control) { text += "⌃" }
        if modifiers.contains(.option) { text += "⌥" }
        if modifiers.contains(.shift) { text += "⇧" }
        if modifiers.contains(.command) { text += "⌘" }
        return text + keySymbol(for: shortcut.key)
      }

      static func accessibilityDescription(for shortcut: KeyboardShortcut) -> String {
        var parts: [String] = []
        let modifiers = shortcut.modifiers
        if modifiers.contains(.control) { parts.append("Control") }
        if modifiers.contains(.option) { parts.append("Option") }
        if modifiers.contains(.shift) { parts.append("Shift") }
        if modifiers.contains(.command) { parts.append("Command") }
        parts.append(keySymbol(for: shortcut.key))
        return parts.joined(separator: " ")
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

      private var effectiveDisabled: Bool { isDisabled || host.isDisabled }
      private var isHighlighted: Bool { highlight.highlighted == id }

      /// The popup's final row (no footer follows) takes the concentric bottom
      /// corners, exactly as a footer would.
      private var isLastInPopup: Bool {
        guard let last = host.targets.last, last.kind == .item else { return false }
        return last.id == AnyHashable(id)
      }

      private var context: ItemContext {
        ItemContext(isHighlighted: isHighlighted, isHovering: isHovering, isDisabled: effectiveDisabled)
      }

      public var body: some View {
        let metrics = style.metrics
        let bottomCornerRadius = isLastInPopup ? metrics.bottomCornerRadius : metrics.itemCornerRadius
        ZStack(alignment: .trailing) {
          Button(action: action) {
            HStack(spacing: metrics.itemIconSpacing) {
              if let icon {
                icon
                  .frame(width: metrics.itemIconSize, height: metrics.itemIconSize)
                  .accessibilityHidden(true)
              }
              label(context)
              Spacer(minLength: 8)
              if let shortcut {
                Text(Self.symbols(for: shortcut))
                  .foregroundStyle(isHighlighted ? AnyShapeStyle(.white.opacity(0.75)) : AnyShapeStyle(.secondary))
                  .accessibilityLabel(Self.accessibilityDescription(for: shortcut))
              }
            }
            .font(metrics.menuFont)
            .foregroundStyle(isHighlighted ? Color.white : Color.primary)
            .padding(.leading, metrics.itemHorizontalInset)
            .padding(.trailing, metrics.itemHorizontalInset + (accessory == nil ? 0 : metrics.itemAccessoryWidth))
            .frame(height: metrics.itemHeight)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
              if isHighlighted {
                HighlightBackground(
                  highlight: style.itemHighlight,
                  topCornerRadius: metrics.itemCornerRadius,
                  bottomCornerRadius: bottomCornerRadius
                )
              }
            }
            .contentShape(
              UnevenRoundedRectangle(
                topLeadingRadius: metrics.itemCornerRadius,
                bottomLeadingRadius: bottomCornerRadius,
                bottomTrailingRadius: bottomCornerRadius,
                topTrailingRadius: metrics.itemCornerRadius,
                style: .continuous
              )
            )
          }
          .buttonStyle(.plain)
          .accessibilityAddTraits(isSelected ? .isSelected : [])
          .accessibilityActions {
            if let accessibilityAction {
              Button(accessibilityAction.name, action: accessibilityAction.perform)
            }
          }

          if let accessory, isHovering, !effectiveDisabled {
            accessory(context)
              .foregroundStyle(isHighlighted ? Color.white : Color.secondary)
              .frame(width: metrics.itemAccessoryWidth, height: metrics.itemHeight)
              .padding(.trailing, metrics.itemAccessoryTrailingInset)
          }
        }
        .disabled(effectiveDisabled)
        .opacity(effectiveDisabled ? 0.55 : 1)
        .onHover { isHovering in
          // A disabled popup ignores the pointer entirely, like a disabled
          // NSMenu item.
          guard !effectiveDisabled else { return }
          self.isHovering = isHovering
          if isHovering {
            highlight.hover(id)
          } else {
            highlight.endHover(id)
          }
        }
        .onChange(of: host.acceptTick) {
          guard host.acceptedID == AnyHashable(id), !effectiveDisabled else { return }
          action()
        }
        .id(AnyHashable(id))
        .preference(key: TargetsKey.self, value: [Target(id: AnyHashable(id), kind: .item)])
      }
    }
  }

  public extension Autocomplete.Item where Accessory == EmptyView {
    init(
      id: ID,
      shortcut: KeyboardShortcut? = nil,
      isSelected: Bool = false,
      isDisabled: Bool = false,
      accessibilityAction: Autocomplete.ItemAction? = nil,
      action: @escaping () -> Void,
      @ViewBuilder icon: () -> Icon,
      @ViewBuilder label: @escaping (Autocomplete.ItemContext) -> Label
    ) {
      self.id = id
      self.icon = icon()
      self.shortcut = shortcut
      self.isSelected = isSelected
      self.isDisabled = isDisabled
      self.accessibilityAction = accessibilityAction
      self.action = action
      self.label = label
      self.accessory = nil
    }
  }

  public extension Autocomplete.Item where Icon == Image {
    init(
      id: ID,
      icon: Image? = nil,
      shortcut: KeyboardShortcut? = nil,
      isSelected: Bool = false,
      isDisabled: Bool = false,
      accessibilityAction: Autocomplete.ItemAction? = nil,
      action: @escaping () -> Void,
      @ViewBuilder label: @escaping (Autocomplete.ItemContext) -> Label,
      @ViewBuilder accessory: @escaping (Autocomplete.ItemContext) -> Accessory
    ) {
      self.id = id
      self.icon = icon
      self.shortcut = shortcut
      self.isSelected = isSelected
      self.isDisabled = isDisabled
      self.accessibilityAction = accessibilityAction
      self.action = action
      self.label = label
      self.accessory = accessory
    }
  }

  public extension Autocomplete.Item where Icon == Image, Accessory == EmptyView {
    init(
      id: ID,
      icon: Image? = nil,
      shortcut: KeyboardShortcut? = nil,
      isSelected: Bool = false,
      isDisabled: Bool = false,
      accessibilityAction: Autocomplete.ItemAction? = nil,
      action: @escaping () -> Void,
      @ViewBuilder label: @escaping (Autocomplete.ItemContext) -> Label
    ) {
      self.id = id
      self.icon = icon
      self.shortcut = shortcut
      self.isSelected = isSelected
      self.isDisabled = isDisabled
      self.accessibilityAction = accessibilityAction
      self.action = action
      self.label = label
      self.accessory = nil
    }
  }

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
        case let .fill(color):
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
#endif
