import Darwin
import Foundation

/// Runtime assets required by Ghostty's exec backend.
///
/// The package owns these assets and always points libghostty at this immutable
/// bundle location before the C runtime initializes. User-level Ghostty
/// resources and configuration are never consulted.
public enum GhosttyRuntimeResources {
    /// The package-bundled Ghostty resource directory.
    ///
    /// Ghostty expects shell integration below this directory and its compiled
    /// terminfo database in a sibling `terminfo` directory.
    public static var directoryURL: URL? {
        // CODEVISOR-PATCH: Codevisor only uses the host-managed backend (no
        // local shell), so the exec backend's resources aren't bundled.
        nil
    }

    /// The compiled terminfo database exported to child shells by Ghostty.
    public static var terminfoDirectoryURL: URL? {
        // CODEVISOR-PATCH: see directoryURL.
        nil
    }

    static func configureEnvironment() {
        guard let path = directoryURL?.path else { return }
        setenv("GHOSTTY_RESOURCES_DIR", path, 1)
    }
}
