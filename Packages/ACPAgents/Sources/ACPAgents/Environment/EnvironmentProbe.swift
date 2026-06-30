import Foundation

/// Checks whether files exist and are executable.
///
/// Abstracted so discovery can be tested with a virtual file system.
public protocol FileProbing: Sendable {
    func isExecutableFile(atPath path: String) -> Bool
}

/// A `FileProbing` backed by `FileManager`.
public struct DefaultFileProbe: FileProbing {
    public init() {}
    public func isExecutableFile(atPath path: String) -> Bool {
        FileManager.default.isExecutableFile(atPath: path)
    }
}

/// Resolves the user's shell environment and locates executables on `PATH`.
///
/// GUI applications inherit a minimal `PATH` that usually excludes Homebrew,
/// nvm, asdf, etc., so the real `PATH` is recovered by asking the user's login
/// shell.
public struct EnvironmentProbe: Sendable {
    private let runner: any CommandRunner
    private let fileProbe: any FileProbing
    private let loginShell: URL
    private let baseEnvironment: [String: String]

    /// Default directories used when the login shell cannot be queried.
    public static let fallbackPathDirectories = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
        "/usr/sbin",
        "/sbin"
    ]

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        fileProbe: any FileProbing = DefaultFileProbe(),
        loginShell: URL = URL(fileURLWithPath: "/bin/zsh"),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.fileProbe = fileProbe
        self.loginShell = loginShell
        self.baseEnvironment = baseEnvironment
    }

    /// Returns the user's `PATH`, querying the login shell and falling back to a
    /// sensible default set of directories.
    public func resolvedPath() async -> String {
        if let result = try? await runner.run(
            executableURL: loginShell,
            arguments: ["-ilc", "echo $PATH"],
            environment: baseEnvironment
        ), result.exitCode == 0 {
            let trimmed = result.standardOutput.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty {
                return mergeWithFallback(trimmed)
            }
        }
        return Self.fallbackPathDirectories.joined(separator: ":")
    }

    /// Returns the environment to pass to launched agents, with `PATH` resolved.
    public func resolvedEnvironment(path: String) -> [String: String] {
        var environment = baseEnvironment
        environment["PATH"] = path
        return environment
    }

    /// Locates an executable by name within a colon-separated `PATH`.
    public func locate(_ name: String, inPath path: String) -> URL? {
        for directory in path.split(separator: ":").map(String.init) where !directory.isEmpty {
            let candidate = (directory as NSString).appendingPathComponent(name)
            if fileProbe.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }

    /// Lists executables in a `PATH` whose file name matches a predicate.
    public func executables(inPath path: String, matching predicate: @Sendable (String) -> Bool) -> [URL] {
        var results: [URL] = []
        let fileManager = FileManager.default
        for directory in path.split(separator: ":").map(String.init) where !directory.isEmpty {
            guard let entries = try? fileManager.contentsOfDirectory(atPath: directory) else { continue }
            for entry in entries where predicate(entry) {
                let fullPath = (directory as NSString).appendingPathComponent(entry)
                if fileProbe.isExecutableFile(atPath: fullPath) {
                    results.append(URL(fileURLWithPath: fullPath))
                }
            }
        }
        return results
    }

    private func mergeWithFallback(_ path: String) -> String {
        var directories = path.split(separator: ":").map(String.init)
        for fallback in Self.fallbackPathDirectories where !directories.contains(fallback) {
            directories.append(fallback)
        }
        return directories.joined(separator: ":")
    }
}
