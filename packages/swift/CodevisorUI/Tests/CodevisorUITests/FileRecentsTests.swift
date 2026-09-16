import Foundation
import Testing

@testable import CodevisorUI

@MainActor struct FileRecentsTests {
  /// A private defaults domain per test keeps the suite order-independent
  /// and never touches the developer's own recents.
  private func makeDefaults() -> UserDefaults {
    let suite = "FileRecentsTests." + UUID().uuidString
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    return defaults
  }

  @Test func recordMovesLatestToFront() {
    let recents = FileRecents(defaults: makeDefaults())
    recents.record("/project/a.swift", machineId: "m", root: "/project")
    recents.record("/project/b.swift", machineId: "m", root: "/project")
    recents.record("/project/a.swift", machineId: "m", root: "/project")
    #expect(recents.paths(machineId: "m", root: "/project") == ["/project/a.swift", "/project/b.swift"])
  }

  @Test func onlyWorkspaceFilesAreRemembered() {
    let recents = FileRecents(defaults: makeDefaults())
    recents.record("/elsewhere/a.swift", machineId: "m", root: "/project")
    recents.record("https://attachments.codevisor.invalid/id?name=a.txt", machineId: "m", root: "/project")
    recents.record("/project/src/", machineId: "m", root: "/project")
    recents.record("/projects/a.swift", machineId: "m", root: "/project")
    #expect(recents.paths(machineId: "m", root: "/project").isEmpty)
  }

  @Test func listIsBoundedAndPersisted() {
    let defaults = makeDefaults()
    let recents = FileRecents(defaults: defaults)
    for index in 0..<(FileRecents.limit + 5) {
      recents.record("/project/\(index).swift", machineId: "m", root: "/project/")
    }
    let expected = (5..<(FileRecents.limit + 5)).reversed().map { "/project/\($0).swift" }
    #expect(recents.paths(machineId: "m", root: "/project") == expected)
    #expect(FileRecents(defaults: defaults).paths(machineId: "m", root: "/project") == expected)
  }

  @Test func scopesAreIsolatedByMachineAndRoot() {
    let recents = FileRecents(defaults: makeDefaults())
    recents.record("/project/a.swift", machineId: "one", root: "/project")
    #expect(recents.paths(machineId: "two", root: "/project").isEmpty)
    #expect(recents.paths(machineId: "one", root: "/other").isEmpty)
    recents.remove("/project/a.swift", machineId: "one", root: "/project")
    #expect(recents.paths(machineId: "one", root: "/project").isEmpty)
  }
}
