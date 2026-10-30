import Foundation

struct ComposerDefaults: Codable, Sendable {
  static let schemaVersion = 7

  var version = Self.schemaVersion
  var lastNewWorkspaceServerId: String?
  var machines: [String: Machine] = [:]
  var harnesses: [String: ComposerHarnessDefaults] = [:]

  struct Machine: Codable, Sendable {
    var lastHarnessId: String?
    var lastProjectId: UUID?
    var newWorkspaceInWorktree: Bool?
    var worktreeByProject: [String: Bool]?
  }
}
