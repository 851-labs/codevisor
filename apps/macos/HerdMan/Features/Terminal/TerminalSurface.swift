import AppKit
import Foundation

/// A live terminal surface: an `NSView` that renders an interactive shell scoped
/// to a working directory. Implemented either by libghostty (when `GhosttyKit`
/// is linked) or by a placeholder (so the app builds and the UI is fully
/// functional before the framework is available).
@MainActor
protocol TerminalSurface: AnyObject {
    /// The view to embed in the terminal panel. The surface owns it for its
    /// whole lifetime so terminal state survives panel close + navigation.
    var nsView: NSView { get }
    /// Routes keyboard focus into (or out of) the terminal.
    func setFocused(_ focused: Bool)
    /// Tears down the shell/PTY and releases resources.
    func terminate()
}

/// Creates terminal surfaces. One factory is selected at launch depending on
/// whether libghostty is linked.
@MainActor
protocol TerminalSurfaceFactory {
    func makeSurface(workingDirectory: URL) -> any TerminalSurface
}

/// Selects the terminal backend. Uses libghostty when `GhosttyKit` is linked,
/// otherwise a buildable placeholder. The real terminal drops in unchanged via
/// the `TerminalSurface` protocol once the framework is present.
@MainActor
enum TerminalRuntime {
    static let factory: any TerminalSurfaceFactory = {
        // SwiftUI previews use the placeholder so they never spawn a real shell
        // (which would fork inside the fork-hostile preview harness).
        if AppPreview.isRunning { return PlaceholderTerminalFactory() }
        #if canImport(GhosttyKit)
        return GhosttyTerminalFactory.shared
        #else
        return PlaceholderTerminalFactory()
        #endif
    }()

    /// Whether a real terminal backend is available. The UI uses this to show a
    /// hint in the placeholder state.
    static var isLive: Bool {
        #if canImport(GhosttyKit)
        return true
        #else
        return false
        #endif
    }

    /// Eagerly initializes the terminal backend at app launch, in a clean
    /// context (not inside a SwiftUI update / event handler). This completes the
    /// libghostty runtime's `dispatch_once`-backed setup up front so opening the
    /// terminal later never re-enters an in-progress `once` (which traps with
    /// `_dispatch_once_wait` / EXC_BREAKPOINT).
    static func prewarm() {
        #if canImport(GhosttyKit)
        _ = GhosttyRuntime.shared.app
        #endif
    }
}
