import ScreenSharing
import Foundation

public struct RigBuildInfo: Codable, Equatable, Sendable {
  public let commit: String
  public let dirty: Bool
  public let configuration: String
  public let builtAt: String

  public init(commit: String, dirty: Bool, configuration: String, builtAt: String) {
    self.commit = commit
    self.dirty = dirty
    self.configuration = configuration
    self.builtAt = builtAt
  }

  public static let unknown = RigBuildInfo(commit: "unknown", dirty: false, configuration: "unspecified", builtAt: "")

  public init(infoDictionary: [String: Any]?) {
    let info = infoDictionary ?? [:]
    commit = info["CodevisorRigCommit"] as? String ?? "unknown"
    dirty = (info["CodevisorRigDirty"] as? Bool) ?? ((info["CodevisorRigDirty"] as? String) == "true")
    configuration = info["CodevisorProbeBuildConfiguration"] as? String ?? "unspecified"
    builtAt = info["CodevisorRigBuiltAt"] as? String ?? ""
  }

  public var label: String { "\(commit.prefix(8))\(dirty ? "*" : "") \(configuration)" }
}
