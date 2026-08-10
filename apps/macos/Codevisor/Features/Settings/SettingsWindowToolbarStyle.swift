import AppKit
import SwiftUI

extension View {
    /// Forces the modern one-row toolbar — back button and title inline at
    /// the leading edge of the detail column (System Settings, Xcode 26) —
    /// on the window hosting this view.
    ///
    /// Needed because the SwiftUI `Settings` scene hard-codes the legacy
    /// `.preference` toolbar style when it creates its window and ignores
    /// the `windowToolbarStyle` scene modifier. That legacy style stacks a
    /// centered window title above the toolbar items, which leaves a pushed
    /// page's back button floating alone on a second row.
    func settingsWindowToolbarStyle() -> some View {
        background(SettingsToolbarStyler())
    }
}

private struct SettingsToolbarStyler: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        StylerView()
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        (nsView as? StylerView)?.apply()
    }

    /// A zero-size probe whose only job is to restyle its window's toolbar.
    private final class StylerView: NSView {
        private var observation: NSObjectProtocol?

        deinit {
            if let observation {
                NotificationCenter.default.removeObserver(observation)
            }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()

            if let observation {
                NotificationCenter.default.removeObserver(observation)
                self.observation = nil
            }
            // Re-assert on window updates: the Settings scene re-derives its
            // toolbar as navigation pushes and pops swap the toolbar items.
            // The guard in apply() makes the common no-op case free.
            if let window {
                observation = NotificationCenter.default.addObserver(
                    forName: NSWindow.didUpdateNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    self?.apply()
                }
            }
            apply()
        }

        func apply() {
            // .unified (not .unifiedCompact): the standard-height toolbar
            // System Settings and Xcode use, where AppKit renders toolbar
            // controls at large size, vertically centered.
            guard let window, window.toolbarStyle != .unified else { return }
            window.toolbarStyle = .unified
        }
    }
}
