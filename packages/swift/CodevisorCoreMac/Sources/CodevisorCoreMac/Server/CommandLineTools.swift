import Foundation

/// Puts the CLI launchers bundled inside the app onto the user's PATH.
///
/// The app is installed three ways — install.sh, the Homebrew cask, and a
/// plain DMG drag — and only the first two run any script. Ensuring the
/// symlinks at launch covers the drag-install case and repairs links after
/// the bundle moves. install.sh and the cask create the same links up front,
/// so the CLI also exists before the app first launches.
///
/// The bundled launchers resolve symlinks before locating their runtime
/// root, so links pointing straight into the bundle work from any PATH
/// directory, and in-place app updates keep them valid.
public enum CommandLineTools {
    public static let launcherNames = [
        "codevisor",
        "codevisor-server",
        "codevisor-terminal-proxy",
    ]

    /// Path fragments identifying a link destination as one of ours. Only
    /// links matching these (or broken links) are ever replaced; Homebrew
    /// formula links, user scripts, and anything else foreign stays put.
    private static let ownedDestinationMarkers = [
        "Codevisor.app/Contents/Resources/",
        "HerdMan.app/Contents/Resources/",
    ]

    /// Ensures `~/.local/bin` symlinks for the bundled CLI launchers.
    /// Deliberately silent: failures (no bundled runtime in development
    /// builds, read-only home) just leave the PATH as it was — the CLI is a
    /// convenience, not a requirement.
    public static func ensureInstalled(
        runtimeDirectory: URL? = LocalCodevisorServer.bundledServerRuntimeDirectory(),
        binDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true),
        fileManager: FileManager = .default
    ) {
        guard let runtimeDirectory else { return }
        let runtimeBin = runtimeDirectory.appendingPathComponent("bin", isDirectory: true)
        for name in launcherNames {
            let source = runtimeBin.appendingPathComponent(name)
            guard fileManager.isExecutableFile(atPath: source.path) else { continue }
            ensureLink(
                at: binDirectory.appendingPathComponent(name),
                to: source,
                fileManager: fileManager
            )
        }
    }

    private static func ensureLink(at link: URL, to source: URL, fileManager: FileManager) {
        if let destination = try? fileManager.destinationOfSymbolicLink(atPath: link.path) {
            let resolved = URL(
                fileURLWithPath: destination,
                relativeTo: link.deletingLastPathComponent()
            ).standardizedFileURL.path
            guard resolved != source.path else { return }
            let broken = !fileManager.fileExists(atPath: resolved)
            let owned = ownedDestinationMarkers.contains { resolved.contains($0) }
            guard broken || owned else { return }
        } else if fileManager.fileExists(atPath: link.path) {
            // A regular file the user (or another tool) put there — not ours
            // to replace.
            return
        }
        do {
            try fileManager.createDirectory(
                at: link.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try? fileManager.removeItem(at: link)
            try fileManager.createSymbolicLink(at: link, withDestinationURL: source)
        } catch {
            // Silent by design (see ensureInstalled).
        }
    }
}
