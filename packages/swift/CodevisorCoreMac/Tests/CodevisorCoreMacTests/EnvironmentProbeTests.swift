import Foundation
import Testing
@testable import CodevisorCore
@testable import CodevisorCoreMac

@Suite("EnvironmentProbe")
struct EnvironmentProbeTests {
  private static let home = "/Users/test"
  private static let fallbacks = EnvironmentProbe.fallbackPathDirectories(home: home)

  private func makeProbe(
    runner: FakeCommandRunner,
    basePath: String? = nil
  ) -> EnvironmentProbe {
    var base = ["HOME": Self.home]
    if let basePath {
      base["PATH"] = basePath
    }
    return EnvironmentProbe(
      runner: runner,
      loginShell: URL(fileURLWithPath: "/bin/zsh"),
      baseEnvironment: base
    )
  }

  @Test("resolvedPath parses env output and merges base PATH plus fallbacks, deduped")
  func resolvedPathSuccess() async {
    let runner = FakeCommandRunner(stdout: "HOME=/Users/test\nPATH=/custom/bin:/usr/bin\nLANG=C\n")
    let probe = makeProbe(runner: runner, basePath: "/base/only:/usr/bin")
    let path = await probe.resolvedPath()
    let directories = path.split(separator: ":").map(String.init)
    // Probed ordering wins, base PATH follows, fallbacks appended, deduped.
    #expect(Array(directories.prefix(2)) == ["/custom/bin", "/usr/bin"])
    #expect(directories.contains("/base/only"))
    #expect(directories.contains("/Users/test/.local/bin"))
    #expect(directories.filter { $0 == "/usr/bin" }.count == 1)
    // It probed the login shell for the real environment (fish-safe).
    #expect(runner.invocations.first?.1 == ["-ilc", "/usr/bin/env"])
  }

  @Test("resolvedPath takes the last PATH line and ignores other lines")
  func resolvedPathLastLineWins() async {
    let runner = FakeCommandRunner(stdout: "PATH=/stale\nOTHER=x\nPATH=/fresh\n")
    let probe = makeProbe(runner: runner)
    let path = await probe.resolvedPath()
    #expect(path.hasPrefix("/fresh"))
    #expect(!path.contains("/stale"))
  }

  @Test("resolvedPath falls back when the shell fails")
  func resolvedPathFailure() async {
    let runner = FakeCommandRunner(.failure(.boom))
    let probe = makeProbe(runner: runner)
    let path = await probe.resolvedPath()
    #expect(path == Self.fallbacks.joined(separator: ":"))
  }

  @Test("resolvedPath keeps the base PATH when the shell output has no PATH line")
  func resolvedPathNoPathLine() async {
    let runner = FakeCommandRunner(stdout: "HOME=/Users/test\n")
    let probe = makeProbe(runner: runner, basePath: "/base/only")
    let path = await probe.resolvedPath()
    #expect(path == (["/base/only"] + Self.fallbacks).joined(separator: ":"))
  }

  @Test("resolvedPath falls back on non-zero exit")
  func resolvedPathNonZeroExit() async {
    let runner = FakeCommandRunner(stdout: "PATH=/x", exitCode: 1)
    let probe = makeProbe(runner: runner)
    let path = await probe.resolvedPath()
    #expect(path == Self.fallbacks.joined(separator: ":"))
  }

  @Test("fallback directories include per-user install locations")
  func fallbackDirectories() {
    #expect(Self.fallbacks.first == "/Users/test/.local/bin")
    #expect(Self.fallbacks.contains("/opt/homebrew/bin"))
    #expect(Self.fallbacks.contains("/Users/test/.volta/bin"))
    #expect(Self.fallbacks.contains("/Users/test/.asdf/shims"))
  }

  @Test("userLoginShell returns a usable shell path")
  func loginShell() {
    // The password database always has a shell for the current user; the
    // env fallback path is exercised with an injected empty environment.
    let shell = EnvironmentProbe.userLoginShell(environment: [:])
    #expect(shell.path.hasPrefix("/"))
    #expect(!shell.path.isEmpty)
  }

  @Test("resolvedEnvironment overrides PATH")
  func resolvedEnvironment() {
    let probe = makeProbe(runner: FakeCommandRunner(stdout: ""))
    let environment = probe.resolvedEnvironment(path: "/a:/b")
    #expect(environment["PATH"] == "/a:/b")
    #expect(environment["HOME"] == "/Users/test")
  }

}
