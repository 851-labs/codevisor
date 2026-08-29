import AppKit
import SwiftUI

enum ModelPickerKeyboardTarget: Hashable {
    case model(groupID: String, value: String)
    case manageHarnesses
}

/// SwiftUI exposes scroll-indicator visibility but not AppKit's native control
/// sizes. This zero-size probe keeps the picker on the system scroller style
/// while using the compact width of a mini vertical scroller.
struct ModelPickerScrollerConfigurator: NSViewRepresentable {
    func makeNSView(context: Context) -> ConfiguratorView {
        ConfiguratorView()
    }

    func updateNSView(_ view: ConfiguratorView, context: Context) {
        view.apply()
    }

    final class ConfiguratorView: NSView {
        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            apply()
        }

        func apply() {
            DispatchQueue.main.async { [weak self] in
                guard
                    let scrollView = self?.enclosingScrollView,
                    let scroller = scrollView.verticalScroller,
                    scroller.controlSize != .mini
                else { return }
                scroller.controlSize = .mini
                scrollView.tile()
            }
        }
    }
}

struct ModelFilterField: NSViewRepresentable {
    @Binding var text: String
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    private static let transparentSearchIcon = NSImage(size: NSSize(width: 1, height: 1))

    func makeCoordinator() -> Coordinator {
        Coordinator(
            text: $text,
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> XcodeModelFilterView {
        let container = XcodeModelFilterView()
        let searchField = container.searchField
        searchField.delegate = context.coordinator
        searchField.placeholderString = "Filter"
        searchField.controlSize = .large
        searchField.font = .menuFont(ofSize: 0)
        searchField.focusRingType = .none
        searchField.sendsSearchStringImmediately = true
        searchField.sendsWholeSearchString = false
        searchField.setAccessibilityLabel("Filter models")
        configureSearchCell(searchField)

        return container
    }

    func updateNSView(_ container: XcodeModelFilterView, context: Context) {
        let searchField = container.searchField
        context.coordinator.text = $text
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        if searchField.stringValue != text {
            searchField.stringValue = text
        }
        configureSearchCell(searchField)

        guard !context.coordinator.didFocus else { return }
        DispatchQueue.main.async {
            guard let window = searchField.window else { return }
            context.coordinator.didFocus = window.makeFirstResponder(searchField)
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

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var text: Binding<String>
        var didFocus = false
        var onMoveUp: () -> Void
        var onMoveDown: () -> Void
        var onSubmit: () -> Void
        var onCancel: () -> Void

        init(
            text: Binding<String>,
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.text = text
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let searchField = notification.object as? NSSearchField else { return }
            text.wrappedValue = searchField.stringValue
        }

        /// The popover-level event monitor keeps navigation working if focus
        /// moves away from the filter. This delegate path uses AppKit's normal
        /// text-command routing while the filter is the first responder.
        func control(
            _ control: NSControl,
            textView: NSTextView,
            doCommandBy commandSelector: Selector
        ) -> Bool {
            switch commandSelector {
            case #selector(NSResponder.moveUp(_:)):
                onMoveUp()
            case #selector(NSResponder.moveDown(_:)):
                onMoveDown()
            case #selector(NSResponder.insertNewline(_:)):
                onSubmit()
            case #selector(NSResponder.cancelOperation(_:)):
                onCancel()
            default:
                return false
            }
            return true
        }
    }
}

/// `NSSearchFieldCell` always paints a white bezel in this presentation. Xcode
/// uses the same native field content inside a darker, menu-specific capsule,
/// so this view owns only that capsule while leaving editing to NSSearchField.
final class XcodeModelFilterView: NSView {
    let searchField = NSSearchField()
    private let capsuleLayer = CAGradientLayer()
    private let filterIcon = NSImageView()

    override var intrinsicContentSize: NSSize {
        NSSize(
            width: NSView.noIntrinsicMetric,
            height: XcodeModelPickerMetrics.searchFieldHeight
        )
    }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.addSublayer(capsuleLayer)

        searchField.translatesAutoresizingMaskIntoConstraints = false
        addSubview(searchField)

        filterIcon.translatesAutoresizingMaskIntoConstraints = false
        filterIcon.image = NSImage(
            systemSymbolName: "magnifyingglass",
            accessibilityDescription: nil
        )?.withSymbolConfiguration(
            NSImage.SymbolConfiguration(pointSize: 13, weight: .regular)
        )
        filterIcon.contentTintColor = .secondaryLabelColor
        addSubview(filterIcon)

        NSLayoutConstraint.activate([
            searchField.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 25),
            searchField.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -1),
            searchField.centerYAnchor.constraint(equalTo: centerYAnchor),
            searchField.heightAnchor.constraint(equalToConstant: 16),
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

    override var wantsUpdateLayer: Bool {
        true
    }

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
                NSColor(
                    srgbRed: 227 / 255,
                    green: 223 / 255,
                    blue: 224 / 255,
                    alpha: 1
                ).cgColor,
                NSColor(
                    srgbRed: 230 / 255,
                    green: 227 / 255,
                    blue: 228 / 255,
                    alpha: 1
                ).cgColor,
            ]
            capsuleLayer.borderColor =
                NSColor(
                    srgbRed: 174 / 255,
                    green: 173 / 255,
                    blue: 173 / 255,
                    alpha: 1
                ).cgColor
        }
        capsuleLayer.locations = [0, 0.45]
        capsuleLayer.startPoint = CGPoint(x: 0.5, y: 1)
        capsuleLayer.endPoint = CGPoint(x: 0.5, y: 0)
        capsuleLayer.borderWidth = 0.5
        capsuleLayer.cornerCurve = .continuous
    }
}

struct ModelPickerKeyMonitor: NSViewRepresentable {
    let onMoveUp: () -> Void
    let onMoveDown: () -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(
            onMoveUp: onMoveUp,
            onMoveDown: onMoveDown,
            onSubmit: onSubmit,
            onCancel: onCancel
        )
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.installMonitor()
        return NSView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onMoveUp = onMoveUp
        context.coordinator.onMoveDown = onMoveDown
        context.coordinator.onSubmit = onSubmit
        context.coordinator.onCancel = onCancel
        context.coordinator.installMonitor()
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.removeMonitor()
    }

    final class Coordinator {
        var onMoveUp: () -> Void
        var onMoveDown: () -> Void
        var onSubmit: () -> Void
        var onCancel: () -> Void

        private var monitor: Any?

        init(
            onMoveUp: @escaping () -> Void,
            onMoveDown: @escaping () -> Void,
            onSubmit: @escaping () -> Void,
            onCancel: @escaping () -> Void
        ) {
            self.onMoveUp = onMoveUp
            self.onMoveDown = onMoveDown
            self.onSubmit = onSubmit
            self.onCancel = onCancel
        }

        func installMonitor() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                guard let self else { return event }
                let modifiers = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
                let shortcutModifiers = modifiers.intersection([.command, .control, .option, .shift])
                if shortcutModifiers == .control {
                    switch event.keyCode {
                    case 38:
                        onMoveDown()
                    case 40:
                        onMoveUp()
                    default:
                        return event
                    }
                    return nil
                }

                guard shortcutModifiers.isEmpty else {
                    return event
                }

                switch event.keyCode {
                case 126:
                    onMoveUp()
                case 125:
                    onMoveDown()
                case 36, 76:
                    onSubmit()
                case 53:
                    onCancel()
                default:
                    return event
                }
                return nil
            }
        }

        func removeMonitor() {
            guard let monitor else { return }
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }

        deinit {
            removeMonitor()
        }
    }
}
