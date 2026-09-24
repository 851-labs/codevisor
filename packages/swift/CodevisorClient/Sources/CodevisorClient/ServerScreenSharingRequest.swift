import Foundation

public struct ServerScreenSharingDisplay: Codable, Sendable, Equatable, Identifiable {
  public let id: String
  public let name: String
  public let width: Int
  public let height: Int
  /// UI scales `setScale` accepts (a VNC desktop the server can scale, 851-2339); nil when it can't.
  public var scales: [Int]?
  /// The size the desktop was provisioned at, for a viewer that stops resizing it.
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

/// Ephemeral signaling only. Never persist this request or SDP in pane metadata.
public struct ServerScreenSharingRequest: Codable, Sendable {
  public enum Operation: String, Codable, Sendable { case capabilities, start, restart, heartbeat, stop, setScale }
  public let version: Int
  public let operation: Operation
  public let workspaceId: UUID
  public let paneId: UUID
  public let viewerId: UUID
  public var displayId: String?
  public var offer: String?
  /// `setScale`: the desktop's UI scale, 1 or 2 (851-2339).
  public var scale: Int?

  public init(
    operation: Operation, workspaceId: UUID, paneId: UUID, viewerId: UUID,
    displayId: String? = nil, offer: String? = nil, scale: Int? = nil
  ) {
    version = 1; self.operation = operation; self.workspaceId = workspaceId
    self.paneId = paneId; self.viewerId = viewerId; self.displayId = displayId; self.offer = offer
    self.scale = scale
  }
}

public struct ServerScreenSharingReply: Codable, Sendable {
  public let version: Int
  public var status: String
  public var message: String?
  public var displays: [ServerScreenSharingDisplay]
  public var answer: String?
  public var connectivity: ServerScreenSharingConnectivity?
  /// "vnc" when the machine streams over the VNC socket route; absent or
  /// "native" for WebRTC from the native helper.
  public var provider: String?

  public init(
    status: String, message: String? = nil, displays: [ServerScreenSharingDisplay] = [], answer: String? = nil,
    connectivity: ServerScreenSharingConnectivity? = nil, provider: String? = nil
  ) {
    version = 1; self.status = status; self.message = message; self.displays = displays; self.answer = answer
    self.connectivity = connectivity
    self.provider = provider
  }
}

public struct ServerScreenSharingConnectivity: Codable, Sendable {
  public struct Server: Codable, Sendable {
    public let urls: [String]
    public let username: String
    public let credential: String
    public init(urls: [String], username: String = "", credential: String = "") {
      self.urls = urls; self.username = username; self.credential = credential
    }
  }
  public let servers: [Server]
  public let relayOnly: Bool
  public let expiresAt: Int
  public init(servers: [Server], relayOnly: Bool, expiresAt: Int) {
    self.servers = servers; self.relayOnly = relayOnly; self.expiresAt = expiresAt
  }
}

extension CodevisorServerClient {
  public func screenSharing(_ request: ServerScreenSharingRequest) async throws -> ServerScreenSharingReply {
    try await send("/v1/screen-sharing", method: "POST", body: request)
  }

  /// The RFB byte stream behind a "vnc:" display, over the machine-authenticated socket route.
  public func screenSharingVNCSocket(displayId: String) throws -> any ServerWebSocketConnecting {
    var query = URLComponents()
    query.queryItems = [URLQueryItem(name: "displayId", value: displayId)]
    let path = "/v1/screen-sharing/vnc/socket?\(query.percentEncodedQuery ?? "")"
    var request = URLRequest(url: try websocketURL(for: path))
    applyAuthorization(to: &request)
    return webSocketTransport.connect(request, maximumMessageSize: 1 << 20)
  }
}

public extension CodevisorServerClienting {
  func screenSharing(_ request: ServerScreenSharingRequest) async throws -> ServerScreenSharingReply {
    throw CodevisorServerClientError.httpStatus(
      501, "Screen Sharing requires an updated Codevisor app on the host Mac.")
  }

  func screenSharingVNCSocket(displayId: String) throws -> any ServerWebSocketConnecting {
    throw CodevisorServerClientError.httpStatus(501, "This machine has no VNC display.")
  }
}
