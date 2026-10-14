import CodevisorCore
import Foundation

public struct EnvironmentProbe: Sendable {
  private let runner: any CommandRunner
  private let loginShell: URL
  private let baseEnvironment: [String: String]

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
      "\(home)/.cargo/bin",
    ]
  }

  public static func userLoginShell() -> URL {
    if let passwd = getpwuid(getuid()), let shell = passwd.pointee.pw_shell {
      let path = String(cString: shell)
      if !path.isEmpty {
        return URL(fileURLWithPath: path)
      }
    }
    if let shell = ProcessInfo.processInfo.environment["SHELL"], !shell.isEmpty {
      return URL(fileURLWithPath: shell)
    }
    return URL(fileURLWithPath: "/bin/zsh")
  }

  public init(
    runner: any CommandRunner = ProcessCommandRunner(),
    loginShell: URL = EnvironmentProbe.userLoginShell(),
    baseEnvironment: [String: String] = ProcessInfo.processInfo.environment
  ) {
    self.runner = runner
    self.loginShell = loginShell
    self.baseEnvironment = baseEnvironment
  }

  public func resolvedPath() async -> String {
    var probed: [String] = []
    do {
      let result = try await runner.run(
        executableURL: loginShell,
        arguments: ["-ilc", "/usr/bin/env"],
        environment: baseEnvironment
      )
      if result.exitCode == 0, let path = Self.pathFromEnvOutput(result.standardOutput) {
        probed = Self.splitPath(path)
      } else {
        Log.server.debug(
          "Login-shell PATH probe yielded no PATH (exit code \(result.exitCode)); using fallback directories"
        )
      }
    } catch {
      Log.server.error(
        "Login-shell PATH probe failed; using fallback directories: \(String(describing: error), privacy: .public)"
      )
    }
    let home = baseEnvironment["HOME"] ?? NSHomeDirectory()
    return Self.mergedPath([
      probed,
      Self.splitPath(baseEnvironment["PATH"]),
      Self.fallbackPathDirectories(home: home),
    ])
  }

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

  public func resolvedEnvironment(path: String) -> [String: String] {
    var environment = baseEnvironment
    environment["PATH"] = path
    return environment
  }
}
