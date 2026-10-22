import Foundation

public struct ServerUpdateRunState: Decodable, Equatable, Sendable {
  public var state: String
  public var harnessIds: [String]
  public var currentHarnessId: String?
  public var pausing: Int

  public init(state: String, harnessIds: [String] = [], currentHarnessId: String? = nil, pausing: Int = 0) {
    self.state = state
    self.harnessIds = harnessIds
    self.currentHarnessId = currentHarnessId
    self.pausing = pausing
  }

  public static let idle = ServerUpdateRunState(state: "idle")

  public var isIdle: Bool { state == "idle" }
  public var isPausing: Bool { state == "pausing" }
  public var isHoldingForAppUpdate: Bool { state == "holding" }

  public func includes(harnessId: String) -> Bool {
    !isIdle && harnessIds.contains(harnessId)
  }
}

public struct ServerUpdateRunRequest: Encodable, Equatable, Sendable {
  public var harnessIds: [String]
  public var serverChannel: String?
  public var holdForAppUpdate: Bool?

  public init(harnessIds: [String], serverChannel: ServerUpdateChannel? = nil, holdForAppUpdate: Bool = false) {
    self.harnessIds = harnessIds
    self.serverChannel = serverChannel?.rawValue
    self.holdForAppUpdate = holdForAppUpdate ? true : nil
  }
}

public struct ServerUpdateRunStarted: Decodable, Equatable, Sendable {
  public var run: ServerUpdateRunState
  public var server: ServerUpdateApplied?

  public init(run: ServerUpdateRunState, server: ServerUpdateApplied? = nil) {
    self.run = run
    self.server = server
  }
}

public enum ServerUpdatePauseSubject: Equatable, Sendable {
  case codevisor
  case harness(id: String, name: String)
}
