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

    /// Well-known executable directories merged into every resolved `PATH` so
    /// detection survives a failed shell probe or an unusual shell setup.
    /// `~/.local/bin` leads: it's the Claude Code native installer's default.
    public static func fallbackPathDirectories(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.local/bin",
            "/opt/homebrew/bin",
            "/usr/local/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin",
            "\(home)/.volta/bin",
            "\(home)/.asdf/shims",
            "\(home)/.bun/bin",
            "\(home)/.cargo/bin"
        ]
    }

    /// The user's actual login shell from the password database — GUI apps
    /// can't rely on `SHELL` being set. Falls back to `SHELL`, then zsh.
    public static func userLoginShell(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let passwd = getpwuid(getuid()), let shell = passwd.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
        }
        if let shell = environment["SHELL"], !shell.isEmpty {
            return URL(fileURLWithPath: shell)
        }
        return URL(fileURLWithPath: "/bin/zsh")
    }

    public init(
        runner: any CommandRunner = ProcessCommandRunner(),
        fileProbe: any FileProbing = DefaultFileProbe(),
        loginShell: URL = EnvironmentProbe.userLoginShell(),
        baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
    ) {
        self.runner = runner
        self.fileProbe = fileProbe
        self.loginShell = loginShell
        self.baseEnvironment = baseEnvironment
    }

    /// Returns the user's `PATH`: the login shell's PATH first (its ordering
    /// wins), then the base environment's PATH, then the fallback directories,
    /// deduplicated. Probing `/usr/bin/env` and parsing the `PATH=` line is
    /// fish-safe — fish echoes `$PATH` space-separated, but the exported
    /// variable is always colon-separated.
    public func resolvedPath() async -> String {
        var probed: [String] = []
        if let result = try? await runner.run(
            executableURL: loginShell,
            arguments: ["-ilc", "/usr/bin/env"],
            environment: baseEnvironment
        ), result.exitCode == 0, let path = Self.pathFromEnvOutput(result.standardOutput) {
            probed = Self.splitPath(path)
        }
        let home = baseEnvironment["HOME"] ?? NSHomeDirectory()
        return Self.mergedPath([
            probed,
            Self.splitPath(baseEnvironment["PATH"]),
            Self.fallbackPathDirectories(home: home)
        ])
    }

    /// Extracts the value of the last `PATH=` line from `env(1)` output.
    static func pathFromEnvOutput(_ output: String) -> String? {
        var path: String?
        for line in output.split(separator: "\n") where line.hasPrefix("PATH=") {
            path = String(line.dropFirst("PATH=".count))
        }
        return path
    }

    private static func splitPath(_ path: String?) -> [String] {
        (path ?? "").split(separator: ":").map(String.init).filter { !$0.isEmpty }
    }

    private static func mergedPath(_ groups: [[String]]) -> String {
        var directories: [String] = []
        for group in groups {
            for directory in group where !directories.contains(directory) {
                directories.append(directory)
            }
        }
        return directories.joined(separator: ":")
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

}
