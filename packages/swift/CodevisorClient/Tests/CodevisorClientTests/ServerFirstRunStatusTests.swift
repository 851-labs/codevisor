import Testing

@testable import CodevisorClient

@Suite("First-run status")
struct ServerFirstRunStatusTests {
  struct Row: CustomTestStringConvertible, Sendable {
    let name: String
    let status: ServerFirstRunStatus
    let isNewInstall: Bool
    var testDescription: String { name }
  }

  static let found = [ServerFirstRunHarness(id: "codex", name: "Codex")]

  static let rows = [
    Row(name: "scan still pending on a new server", status: .init(state: .running), isNewInstall: true),
    Row(name: "scan finished this boot", status: .init(state: .done, harnesses: found), isNewInstall: true),
    Row(
      name: "scan failed this boot after finding harnesses", status: .init(state: .failed, harnesses: found),
      isNewInstall: true),
    Row(name: "scan finished on an earlier boot", status: .init(state: .done), isNewInstall: false),
    Row(name: "server that predates first runs", status: .init(state: .notApplicable), isNewInstall: false),
    Row(name: "scan failed this boot before finding harnesses", status: .init(state: .failed), isNewInstall: true),
  ]

  @Test("Treats only a server still on its first run as a new install", arguments: rows)
  func newInstall(row: Row) {
    #expect(row.status.isNewInstall == row.isNewInstall)
  }
}
