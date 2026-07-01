import AppKit
import Foundation
import HerdManCore

/// A stand-in terminal used until `GhosttyKit` is linked. It renders a dark,
/// terminal-styled panel that names the working directory and explains how to
/// enable the real terminal. This keeps the whole feature (panel, toggle, ⌘J,
/// focus, caching, resize) buildable and verifiable without libghostty.
@MainActor
final class PlaceholderTerminalSurface: TerminalSurface {
    let nsView: NSView
    private let descriptor: TerminalLaunchDescriptor

    init(descriptor: TerminalLaunchDescriptor) {
        self.descriptor = descriptor
        self.nsView = PlaceholderTerminalView(descriptor: descriptor)
    }

    func setFocused(_ focused: Bool) {
        (nsView as? PlaceholderTerminalView)?.setFocusedAppearance(focused)
    }

    func terminate() {}
}

@MainActor
struct PlaceholderTerminalFactory: TerminalSurfaceFactory {
    func makeSurface(descriptor: TerminalLaunchDescriptor) -> any TerminalSurface {
        PlaceholderTerminalSurface(descriptor: descriptor)
    }
}

/// The placeholder's view: a faux prompt line plus an explanatory note.
private final class PlaceholderTerminalView: NSView {
    private let caret = NSView()

    init(descriptor: TerminalLaunchDescriptor) {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.backgroundColor = NSColor(calibratedWhite: 0.07, alpha: 1).cgColor

        let prompt = NSTextField(labelWithString: "\(descriptor.machine.name) %")
        prompt.font = .monospacedSystemFont(ofSize: 12, weight: .regular)
        prompt.textColor = NSColor(calibratedRed: 0.55, green: 0.85, blue: 0.6, alpha: 1)
        prompt.translatesAutoresizingMaskIntoConstraints = false

        caret.wantsLayer = true
        caret.layer?.backgroundColor = NSColor(calibratedWhite: 0.8, alpha: 1).cgColor
        caret.translatesAutoresizingMaskIntoConstraints = false

        let note = NSTextField(wrappingLabelWithString:
            "Terminal preview — link GhosttyKit.xcframework to run the HerdMan terminal proxy.\nServer: \(descriptor.machine.baseURL.absoluteString)\nWorking directory: \(descriptor.workingDirectory.path)")
        note.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        note.textColor = NSColor(calibratedWhite: 0.5, alpha: 1)
        note.translatesAutoresizingMaskIntoConstraints = false

        addSubview(prompt)
        addSubview(caret)
        addSubview(note)

        NSLayoutConstraint.activate([
            prompt.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            prompt.topAnchor.constraint(equalTo: topAnchor, constant: 12),
            caret.leadingAnchor.constraint(equalTo: prompt.trailingAnchor, constant: 6),
            caret.centerYAnchor.constraint(equalTo: prompt.centerYAnchor),
            caret.widthAnchor.constraint(equalToConstant: 7),
            caret.heightAnchor.constraint(equalToConstant: 14),
            note.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 12),
            note.trailingAnchor.constraint(lessThanOrEqualTo: trailingAnchor, constant: -12),
            note.topAnchor.constraint(equalTo: prompt.bottomAnchor, constant: 14)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func setFocusedAppearance(_ focused: Bool) {
        caret.layer?.opacity = focused ? 1 : 0.35
    }
}
