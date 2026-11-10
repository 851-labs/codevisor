import Foundation

enum ParentSessionReference: Equatable {
  case sameMachine(sessionId: UUID)
  case otherMachine(serverId: String, sessionId: UUID)

  init?(_ key: String?) {
    guard let key else { return nil }
    if let sessionId = UUID(uuidString: key) {
      self = .sameMachine(sessionId: sessionId)
      return
    }
    guard let remote = Self.remote(key) else { return nil }
    self = remote
  }

  var sessionId: UUID {
    switch self {
    case let .sameMachine(sessionId), let .otherMachine(_, sessionId): sessionId
    }
  }

  func isHosted(
    by parent: Workspace, of child: Workspace, reportedServerIds: [UUID: String]
  ) -> Bool {
    switch self {
    case .sameMachine: parent.serverId == child.serverId
    case let .otherMachine(serverId, _): reportedServerIds[parent.id] == serverId
    }
  }

  private static let encodedPrefix = "remote2:"
  private static let legacyPrefix = "remote:"

  private static func remote(_ key: String) -> ParentSessionReference? {
    if key.hasPrefix(encodedPrefix) { return encoded(key.dropFirst(encodedPrefix.count)) }
    if key.hasPrefix(legacyPrefix) { return legacy(key.dropFirst(legacyPrefix.count)) }
    return nil
  }

  private static func encoded(_ body: Substring) -> ParentSessionReference? {
    let parts = body.split(separator: ":", omittingEmptySubsequences: false)
    guard parts.count == 2 else { return nil }
    return otherMachine(parts[0].removingPercentEncoding, parts[1].removingPercentEncoding)
  }

  private static func legacy(_ body: Substring) -> ParentSessionReference? {
    var parts = body.split(separator: ":", omittingEmptySubsequences: false)
    let sessionId = parts.removeLast()
    return otherMachine(parts.joined(separator: ":"), String(sessionId))
  }

  private static func otherMachine(_ serverId: String?, _ sessionId: String?) -> ParentSessionReference? {
    guard let serverId, !serverId.isEmpty, let sessionId = sessionId.flatMap(UUID.init(uuidString:)) else {
      return nil
    }
    return .otherMachine(serverId: serverId, sessionId: sessionId)
  }
}
