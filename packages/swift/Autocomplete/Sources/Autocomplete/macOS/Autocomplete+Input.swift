#if canImport(AppKit)
  import AppKit
  import SwiftUI

  public extension Autocomplete {
    /// An imperative handle for giving an `Input` keyboard focus: hosts call
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

    /// The filter field at the top of a popup: a native `NSSearchField` (so
    /// editing, IME, and text commands behave) inside the darker capsule
    /// Xcode draws in its menu-hosted pickers. Takes first responder when it
    /// appears and routes ↑ ↓ ⏎ ⎋ to the enclosing `Root`.
    struct Input: View {
      @Binding var text: String
      let prompt: String
      let accessibilityLabel: String
      let focusesOnAppear: Bool
      let focus: InputFocus?

      @Environment(\.autocompleteStyle) private var style
      @Environment(Host.self) private var host

      /// - Parameters:
      ///   - focusesOnAppear: Take keyboard focus as soon as the field is on
      ///     screen. Right for a popup that is itself presented (a popover);
      ///     wrong for one rendered inline, where focus belongs to whatever
      ///     the user is working in until the host hands it over.
      ///   - focus: An imperative handle; each `focus()` call makes the field
      ///     first responder.
      public init(
        text: Binding<String>,
        prompt: String = "Filter",
        accessibilityLabel: String? = nil,
        focusesOnAppear: Bool = false,
        focus: InputFocus? = nil
      ) {
        _text = text
        self.prompt = prompt
        self.accessibilityLabel = accessibilityLabel ?? prompt
        self.focusesOnAppear = focusesOnAppear
        self.focus = focus
      }

      public var body: some View {
        let metrics = style.metrics
        InputField(
          text: $text,
          prompt: prompt,
          accessibilityLabel: accessibilityLabel,
          focusesOnAppear: focusesOnAppear,
          focusTick: focus?.requestTick ?? 0,
          onCommand: host.send,
          register: { host.inputField = $0 }
        )
        .frame(height: metrics.inputHeight)
        .padding(.horizontal, metrics.inputHorizontalInset)
        .padding(.top, metrics.inputTopInset)
        .padding(.bottom, metrics.inputBottomInset)
        .accessibilityLabel(accessibilityLabel)
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
      let onCommand: (KeyCommand) -> Void
      let register: (NSSearchField) -> Void

      @Environment(\.autocompleteStyle) private var style

      private static let transparentSearchIcon = NSImage(size: NSSize(width: 1, height: 1))

      func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onCommand: onCommand)
      }

      func makeNSView(context: Context) -> InputCapsuleView {
        let container = InputCapsuleView(height: style.metrics.inputHeight)
        let searchField = container.searchField
        searchField.delegate = context.coordinator
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
        context.coordinator.text = $text
        context.coordinator.onCommand = onCommand
        container.prompt = prompt
        container.showsPrompt = text.isEmpty
        searchField.setAccessibilityLabel(accessibilityLabel)
        if searchField.stringValue != text {
          searchField.stringValue = text
        }
        configureSearchCell(searchField)

        let coordinator = context.coordinator
        let wantsInitialFocus = focusesOnAppear && !coordinator.didFocus
        let wantsRequestedFocus = focusTick != coordinator.handledFocusTick
        guard wantsInitialFocus || wantsRequestedFocus else { return }
        coordinator.handledFocusTick = focusTick
        DispatchQueue.main.async {
          guard let window = searchField.window else { return }
          if window.makeFirstResponder(searchField) {
            coordinator.didFocus = true
          }
        }
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
        var onCommand: (KeyCommand) -> Void

        init(text: Binding<String>, onCommand: @escaping (KeyCommand) -> Void) {
          self.text = text
          self.onCommand = onCommand
        }

        func controlTextDidChange(_ notification: Notification) {
          guard let searchField = notification.object as? NSSearchField else { return }
          (searchField.superview as? InputCapsuleView)?.showsPrompt = searchField.stringValue.isEmpty
          text.wrappedValue = searchField.stringValue
        }

        /// `Root`'s key monitor keeps navigation working if focus moves away
        /// from the input. This delegate path uses AppKit's normal
        /// text-command routing while the input is first responder.
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
          switch commandSelector {
          case #selector(NSResponder.moveUp(_:)): onCommand(.moveUp)
          case #selector(NSResponder.moveDown(_:)): onCommand(.moveDown)
          case #selector(NSResponder.insertNewline(_:)): onCommand(.accept)
          case #selector(NSResponder.cancelOperation(_:)): onCommand(.dismiss)
          default: return false
          }
          return true
        }
      }
    }

    /// `NSSearchFieldCell` always paints a white bezel in this presentation.
    /// Xcode uses the same native field content inside a darker, menu-specific
    /// capsule, so this view owns only that capsule while leaving editing to
    /// NSSearchField.
    final class InputCapsuleView: NSView {
      /// Where the field's text begins, past the magnifier.
      static let textLeadingInset: CGFloat = 25

      let searchField = NSSearchField()
      private let promptLabel = NSTextField(labelWithString: "")
      private let capsuleLayer = CAGradientLayer()
      private let filterIcon = NSImageView()
      private let height: CGFloat

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

      init(height: CGFloat) {
        self.height = height
        super.init(frame: .zero)
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
        filterIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)?
          .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 13, weight: .regular))
        filterIcon.contentTintColor = .secondaryLabelColor
        addSubview(filterIcon)

        NSLayoutConstraint.activate([
          searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: Self.textLeadingInset),
          searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
          searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
          searchField.heightAnchor.constraint(equalToConstant: 16),
          // NSSearchFieldCell insets its text by a point; match it
          // so the prompt sits exactly where typed text will.
          promptLabel.leadingAnchor.constraint(equalTo: searchField.leadingAnchor, constant: 1),
          promptLabel.trailingAnchor.constraint(lessThanOrEqualTo: searchField.trailingAnchor),
          promptLabel.firstBaselineAnchor.constraint(equalTo: searchField.firstBaselineAnchor),
          filterIcon.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 7),
          filterIcon.centerYAnchor.constraint(equalTo: centerYAnchor),
          filterIcon.widthAnchor.constraint(equalToConstant: 15),
          filterIcon.heightAnchor.constraint(equalToConstant: 15),
        ])
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
        if isDark {
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
        capsuleLayer.borderWidth = 0.5
        capsuleLayer.cornerCurve = .continuous
      }
    }
  }
#endif
