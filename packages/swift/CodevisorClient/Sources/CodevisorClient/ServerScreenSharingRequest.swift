import Foundation

public struct ServerScreenSharingDisplay: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let width: Int
  public let height: Int
  public var scales: [Int]?
  public var defaultWidth: Int?
  public var defaultHeight: Int?
  public init(
    id: String, name: String, width: Int, height: Int, scales: [Int]? = nil, defaultWidth: Int? = nil,
    defaultHeight: Int? = nil
  ) {
    self.id = id; self.name = name; self.width = width; self.height = height
    self.scales = scales; self.defaultWidth = defaultWidth; self.defaultHeight = defaultHeight
  }
}

public struct ServerScreenSharingRequest: Codable, Sendable {
  public enum Operation: String, Codable, Sendable { case capabilities, start, restart, heartbeat, stop, setScale }
  public enum Intent: String, Codable, Sendable { case open, attach }
  public let version: Int
  public let operation: Operation
  public let workspaceId: UUID
  public let paneId: UUID
  public let viewerId: UUID
  public var displayId: String?
  public var scale: Int?
  public var engine: String?
  public var media: ServerScreenSharingMediaAddress?
  public var chroma: String?
  public var app: ServerScreenSharingApp?
  public var intent: Intent?
  public var proof: ServerScreenSharingProof?
  public var session: String?

  public init(
    operation: Operation, workspaceId: UUID, paneId: UUID, viewerId: UUID,
    displayId: String? = nil, scale: Int? = nil
  ) {
    version = 1; self.operation = operation; self.workspaceId = workspaceId
    self.paneId = paneId; self.viewerId = viewerId; self.displayId = displayId
    self.scale = scale
  }
}

public struct ServerScreenSharingReply: Codable, Sendable {
  public let version: Int
  public var status: String
  public var message: String?
  public var displays: [ServerScreenSharingDisplay]
  public var provider: String?
  public var controlLease: Bool?
  public var engines: [String]?
  public var media: ServerScreenSharingMediaGrant?
  public var abilities: [String]?
  public var reason: ServerScreenSharingReason?
  public var holderName: String?
  public var display: ServerScreenSharingDisplay?
  public var challenge: ServerScreenSharingChallenge?
  public var session: String?

  public static let appSessions = "app-sessions"

  public init(
    status: String, message: String? = nil, displays: [ServerScreenSharingDisplay] = [], provider: String? = nil
  ) {
    version = 1; self.status = status; self.message = message; self.displays = displays
    self.provider = provider
  }
}

public struct ServerScreenSharingMediaAddress: Codable, Sendable, Equatable {
  public let endpointId: String
  public let relayUrl: String?
  public let directAddrs: [String]
  public init(endpointId: String, relayUrl: String?, directAddrs: [String]) {
    self.endpointId = endpointId; self.relayUrl = relayUrl; self.directAddrs = directAddrs
  }
}

public struct ServerScreenSharingMediaGrant: Codable, Sendable, Equatable {
  public let endpointId: String
  public let relayUrl: String?
  public let directAddrs: [String]
  public let token: String
  public init(endpointId: String, relayUrl: String?, directAddrs: [String], token: String) {
    self.endpointId = endpointId; self.relayUrl = relayUrl; self.directAddrs = directAddrs; self.token = token
  }

  public var address: ServerScreenSharingMediaAddress {
    .init(endpointId: endpointId, relayUrl: relayUrl, directAddrs: directAddrs)
  }
}

extension CodevisorServerClient {
  public func screenSharing(_ request: ServerScreenSharingRequest) async throws -> ServerScreenSharingReply {
    try await send("/v1/screen-sharing", method: "POST", body: request)
  }

  public func screenSharingVNCSocket(displayId: String) throws -> any ServerWebSocketConnecting {
    var query = URLComponents()
    query.queryItems = [URLQueryItem(name: "displayId", value: displayId)]
    let path = "/v1/screen-sharing/vnc/socket?\(query.percentEncodedQuery ?? "")"
    var request = URLRequest(url: try websocketURL(for: path))
    applyAuthorization(to: &request)
    return webSocketTransport.connect(request, maximumMessageSize: 1 << 20)
  }

  public func livePreviewSocket(sessionId: UUID) throws -> any ServerWebSocketConnecting {
    var query = URLComponents()
    query.queryItems = [URLQueryItem(name: "sessionId", value: sessionId.uuidString.lowercased())]
    let path = "/v1/live-preview/socket?\(query.percentEncodedQuery ?? "")"
    var request = URLRequest(url: try websocketURL(for: path))
    applyAuthorization(to: &request)
    return webSocketTransport.connect(request, maximumMessageSize: 8 << 20)
  }
}

public extension CodevisorServerClienting {
  var isReconnecting: Bool { false }

  func screenSharing(_ request: ServerScreenSharingRequest) async throws -> ServerScreenSharingReply {
    throw CodevisorServerClientError.httpStatus(
      501, "Screen Sharing requires an updated Codevisor app on the host Mac.")
  }

  func screenSharingVNCSocket(displayId: String) throws -> any ServerWebSocketConnecting {
    throw CodevisorServerClientError.httpStatus(501, "This machine has no VNC display.")
  }

  func livePreviewSocket(sessionId: UUID) throws -> any ServerWebSocketConnecting {
    throw CodevisorServerClientError.httpStatus(501, "This machine has no live preview.")
  }
}
