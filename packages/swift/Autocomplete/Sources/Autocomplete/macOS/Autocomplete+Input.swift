#if canImport(AppKit)
  import AppKit
  import SwiftUI

  public extension Autocomplete {
    /// An imperative handle for giving inline suggestions keyboard focus: hosts call
    /// `focus()` when their surface becomes active (a pane gaining focus, a
    /// palette being summoned) instead of the field grabbing focus by
    /// itself.
    @MainActor
    @Observable
    final class InputFocus {
      public private(set) var requestTick = 0

      public init() {}

      public func focus() {
        requestTick += 1
      }
    }

  }

  extension Autocomplete {
    struct InputField: NSViewRepresentable {
      @Binding var text: String
      let prompt: String
      let accessibilityLabel: String
      let focusesOnAppear: Bool
      let focusTick: Int
      let showsCheckmarks: Bool
      let showsIcons: Bool
      let onCommand: (KeyCommand) -> Bool
      let register: (NSSearchField) -> Void
      var onFocusChange: (Bool) -> Void = { _ in }
      var onKeyEquivalent: (NSEvent) -> Bool = { _ in false }
      var requestedFocus: Bool?
      var onAdvanceFocus: () -> Bool = { false }

      @Environment(\.autocompleteStyle) private var style
      @Environment(\.layoutDirection) private var layoutDirection
      @Environment(\.isEnabled) private var isEnabled

      private static let transparentSearchIcon = NSImage(size: NSSize(width: 1, height: 1))

      func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommand: onCommand, onFocusChange: onFocusChange, onAdvanceFocus: onAdvanceFocus)
      }

      func makeNSView(context: Context) -> InputCapsuleView {
        let container = InputCapsuleView(
          metrics: style.metrics, showsCheckmarks: showsCheckmarks, showsIcons: showsIcons
        )
        let searchField = container.searchField
        searchField.delegate = context.coordinator
        searchField.onKeyEquivalent = onKeyEquivalent
        searchField.isEnabled = isEnabled
        // NSSearchField centers its own placeholder whenever it is not first
        // responder (and ignores `centersPlaceholder`); the capsule draws a
        // leading-aligned one with the same AppKit metrics instead.
        searchField.placeholderString = ""
        container.prompt = prompt
        container.showsPrompt = text.isEmpty
        searchField.controlSize = .large
        searchField.font = style.metrics.nativeMenuFont
        container.syncPromptFont()
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel(accessibilityLabel)
        configureSearchCell(searchField)
        register(searchField)
        return container
      }

      func updateNSView(_ container: InputCapsuleView, context: Context) {
        let searchField = container.searchField
        searchField.onKeyEquivalent = onKeyEquivalent
        searchField.isEnabled = isEnabled
        context.coordinator.text = $text
        context.coordinator.onCommand = onCommand
        context.coordinator.onFocusChange = onFocusChange
        context.coordinator.onAdvanceFocus = onAdvanceFocus
        container.userInterfaceLayoutDirection = layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        searchField.baseWritingDirection = layoutDirection == .rightToLeft ? .rightToLeft : .leftToRight
        container.configure(metrics: style.metrics, showsCheckmarks: showsCheckmarks, showsIcons: showsIcons)
        container.prompt = prompt
        container.showsPrompt = text.isEmpty
        searchField.setAccessibilityLabel(accessibilityLabel)
        if searchField.stringValue != text,
          (searchField.currentEditor() as? NSTextView)?.hasMarkedText() != true
        {
          searchField.stringValue = text
        }
        configureSearchCell(searchField)

        if !isEnabled || requestedFocus == false {
          container.requestFocus = nil
          if let editor = searchField.window?.firstResponder as? NSTextView, editor.delegate === searchField {
            searchField.window?.makeFirstResponder(nil)
          }
          return
        }
        let coordinator = context.coordinator
        let wantsInitialFocus = focusesOnAppear && !coordinator.didFocus
        let wantsRequestedFocus = focusTick != coordinator.handledFocusTick
        let ownsEditor = (searchField.window?.firstResponder as? NSTextView)?.delegate === searchField
        let wantsBoundFocus = requestedFocus == true && !ownsEditor
        guard wantsInitialFocus || wantsRequestedFocus || wantsBoundFocus else { return }
        container.requestFocus = { [weak container] in
          guard let field = container?.searchField, let window = field.window else { return }
          if window.makeFirstResponder(field) {
            coordinator.didFocus = true
            coordinator.handledFocusTick = focusTick
            container?.requestFocus = nil
          }
        }
        DispatchQueue.main.async { [weak container] in container?.requestFocus?() }
      }

      private func configureSearchCell(_ searchField: NSSearchField) {
        guard let searchCell = searchField.cell as? NSSearchFieldCell else { return }
        searchCell.isBezeled = false
        searchCell.isBordered = false
        searchCell.drawsBackground = false
        searchCell.searchButtonCell?.image = Self.transparentSearchIcon
        searchCell.searchButtonCell?.imageScaling = .scaleProportionallyDown
      }

      @MainActor
      final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var didFocus = false
        var handledFocusTick = 0
        var onCommand: (KeyCommand) -> Bool
        var onFocusChange: (Bool) -> Void
        var onAdvanceFocus: () -> Bool

        init(
          text: Binding<String>, onCommand: @escaping (KeyCommand) -> Bool,
          onFocusChange: @escaping (Bool) -> Void = { _ in },
          onAdvanceFocus: @escaping () -> Bool = { false }
        ) {
          self.text = text
          self.onCommand = onCommand
          self.onFocusChange = onFocusChange
          self.onAdvanceFocus = onAdvanceFocus
        }

        func controlTextDidChange(_ notification: Notification) {
          guard let searchField = notification.object as? NSSearchField else { return }
          (searchField.superview as? InputCapsuleView)?.showsPrompt = searchField.stringValue.isEmpty
          text.wrappedValue = searchField.stringValue
        }

        /// The surface’s key monitor keeps navigation working if focus moves away
        /// from the input. This delegate path uses AppKit's normal
        /// text-command routing while the input is first responder.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
          guard !textView.hasMarkedText() else { return false }
          switch commandSelector {
          case #selector(NSResponder.insertTab(_:)): return onAdvanceFocus()
          case #selector(NSResponder.moveUp(_:)): return onCommand(.moveUp)
          case #selector(NSResponder.moveDown(_:)): return onCommand(.moveDown)
          case #selector(NSResponder.insertNewline(_:)): return onCommand(.accept)
          case #selector(NSResponder.cancelOperation(_:)): return onCommand(.dismiss)
          default: return false
          }
        }

        func controlTextDidBeginEditing(_ notification: Notification) { onFocusChange(true) }
        func controlTextDidEndEditing(_ notification: Notification) { onFocusChange(false) }
      }
    }

    final class SearchField: NSSearchField {
      var onKeyEquivalent: (NSEvent) -> Bool = { _ in false }
      override func performKeyEquivalent(with event: NSEvent) -> Bool {
        onKeyEquivalent(event) || super.performKeyEquivalent(with: event)
      }
    }

    /// `NSSearchFieldCell` always paints a white bezel in this presentation.
    /// Xcode uses the same native field content inside a darker, menu-specific
    /// capsule, so this view owns only that capsule while leaving editing to
    /// NSSearchField.
    final class InputCapsuleView: NSView {
      let searchField = SearchField()
      private let promptLabel = NSTextField(labelWithString: "")
      private let capsuleLayer = CAGradientLayer()
      private let filterIcon = NSImageView()
      private var height: CGFloat
      private var configuration: Configuration?
      private var layoutConstraints: [NSLayoutConstraint] = []
      var requestFocus: (() -> Void)?

      private struct Configuration: Equatable {
        let metrics: Metrics
        let checks: Bool
        let icons: Bool
        let direction: NSUserInterfaceLayoutDirection
      }

      var prompt: String {
        get { promptLabel.stringValue }
        set { promptLabel.stringValue = newValue }
      }

      var showsPrompt: Bool {
        get { !promptLabel.isHidden }
        set { promptLabel.isHidden = !newValue }
      }

      func syncPromptFont() {
        promptLabel.font = searchField.font
      }

      override var intrinsicContentSize: NSSize {
        NSSize(width: NSView.noIntrinsicMetric, height: height)
      }

      /// NSSearchField draws its text about a point in from its leading edge;
      /// the field is offset so the text lands on the shared keyline.
      private static let fieldTextInset: CGFloat = 1

      /// The compact layout for popups without an icon column: magnifier at
      /// the capsule's leading edge, text right after it.
      private static let compactIconLeading: CGFloat = 7

      init(metrics: Autocomplete.Metrics, showsCheckmarks: Bool, showsIcons: Bool) {
        height = metrics.inputHeight
        super.init(frame: .zero)
        // With an icon column the magnifier and text sit on the rows'
        // keylines. The capsule sits `inputHorizontalInset` in from the
        // popup edge, so the popup-relative keylines shift by that much.
        wantsLayer = true
        layer?.addSublayer(capsuleLayer)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        promptLabel.translatesAutoresizingMaskIntoConstraints = false
        promptLabel.font = searchField.font
        promptLabel.textColor = .placeholderTextColor
        promptLabel.lineBreakMode = .byTruncatingTail
        promptLabel.setAccessibilityElement(false)
        addSubview(promptLabel)

        filterIcon.translatesAutoresizingMaskIntoConstraints = false
        filterIcon.setAccessibilityElement(false)
        filterIcon.contentTintColor = .secondaryLabelColor
        addSubview(filterIcon)

        configure(metrics: metrics, showsCheckmarks: showsCheckmarks, showsIcons: showsIcons)

      }

      func configure(metrics: Metrics, showsCheckmarks: Bool, showsIcons: Bool) {
        let next = Configuration(
          metrics: metrics, checks: showsCheckmarks, icons: showsIcons,
          direction: userInterfaceLayoutDirection)
        guard configuration != next else { return }
        configuration = next
        height = metrics.inputHeight
        searchField.font = metrics.nativeMenuFont
        filterIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
          .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: metrics.fontSize, weight: .regular))
        syncPromptFont()
        NSLayoutConstraint.deactivate(layoutConstraints)
        let iconCenter: CGFloat
        let textLeading: CGFloat
        if showsIcons {
          iconCenter = metrics.iconColumnCenter(showsCheckmarks: showsCheckmarks) - metrics.inputHorizontalInset
          textLeading =
            metrics.textLeading(showsCheckmarks: showsCheckmarks, showsIcons: true) - metrics.inputHorizontalInset
        } else {
          iconCenter = Self.compactIconLeading + metrics.itemIconSize / 2
          textLeading = Self.compactIconLeading + metrics.itemIconSize + metrics.itemIconSpacing + Self.fieldTextInset
        }
        layoutConstraints = [
          searchField.leadingAnchor.constraint(
            equalTo: leadingAnchor, constant: textLeading - Self.fieldTextInset
          ),
          searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
          // Measured on a 2× display: the field draws its text and cancel
          // button half a point low, and the magnifier glyph (its handle
          // hangs below the lens) reads three quarters of a point high when
          // its image bounds are centered. Nudge both onto the capsule's
          // center line.
          searchField.centerYAnchor.constraint(equalTo: centerYAnchor, constant: -0.5),
          searchField.heightAnchor.constraint(
            equalToConstant: max(16, metrics.nativeMenuFont.ascender - metrics.nativeMenuFont.descender)),
          // The prompt sits exactly where typed text will.
          promptLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: Self.fieldTextInset),
          promptLabel.trailingAnchor.constraint(lessThanOrEqualTo: searchField.trailingAnchor),
          promptLabel.firstBaselineAnchor.constraint(equalTo: searchField.firstBaselineAnchor),
          filterIcon.centerXAnchor.constraint(
            equalTo: leadingAnchor, constant: iconCenter),
          filterIcon.centerYAnchor.constraint(equalTo: centerYAnchor, constant: 0.5),
          filterIcon.widthAnchor.constraint(equalToConstant: metrics.itemIconSize),
          filterIcon.heightAnchor.constraint(equalToConstant: metrics.itemIconSize),
        ]
        NSLayoutConstraint.activate(layoutConstraints)
        invalidateIntrinsicContentSize()
        needsLayout = true
      }

      override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        requestFocus?()
      }

      @available(*, unavailable)
      required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
      }

      override var wantsUpdateLayer: Bool { true }

      override func layout() {
        super.layout()
        capsuleLayer.frame = bounds
        capsuleLayer.cornerRadius = bounds.height / 2
      }

      override func hitTest(_ point: NSPoint) -> NSView? {
        guard bounds.contains(point) else { return nil }
        let searchPoint = convert(point, to: searchField)
        return searchField.hitTest(searchPoint) ?? searchField
      }

      override func updateLayer() {
        let isDark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        if NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast {
          let fill = NSColor.controlBackgroundColor.cgColor
          capsuleLayer.colors = [fill, fill]
          capsuleLayer.borderColor = NSColor.labelColor.cgColor
        } else if isDark {
          let fill = NSColor(calibratedWhite: 0.22, alpha: 1).cgColor
          capsuleLayer.colors = [fill, fill]
          capsuleLayer.borderColor = NSColor(calibratedWhite: 0.39, alpha: 1).cgColor
        } else {
          capsuleLayer.colors = [
            NSColor(srgbRed: 227 / 255, green: 223 / 255, blue: 224 / 255, alpha: 1).cgColor,
            NSColor(srgbRed: 230 / 255, green: 227 / 255, blue: 228 / 255, alpha: 1).cgColor,
          ]
          capsuleLayer.borderColor = NSColor(srgbRed: 174 / 255, green: 173 / 255, blue: 173 / 255, alpha: 1).cgColor
        }
        capsuleLayer.locations = [0, 0.45]
        capsuleLayer.startPoint = CGPoint(x: 0.5, y: 1)
        capsuleLayer.endPoint = CGPoint(x: 0.5, y: 0)
        capsuleLayer.borderWidth = NSWorkspace.shared.accessibilityDisplayShouldIncreaseContrast ? 1 : 0.5
        capsuleLayer.cornerCurve = .continuous
      }
    }
  }
#endif
