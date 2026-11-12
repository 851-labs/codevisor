public enum ScreenSharingConnectStage: String, CaseIterable, Sendable {
  case reachingHost
  case startingHost
  case connectingMedia
  case handshake
  case waitingForVideo

  public static let deadline: Duration = .seconds(10)
  public static let stillConnectingAfter: Duration = .seconds(4)
  public static let reconnectingTunnelGrace: Duration = .seconds(5)

  public func step(on machine: String) -> String {
    switch self {
    case .reachingHost, .startingHost: "Reaching \(machine)…"
    case .connectingMedia, .handshake: "Setting up video…"
    case .waitingForVideo: "Waiting for the screen…"
    }
  }

  public var failure: String {
    switch self {
    case .reachingHost:
      "The machine didn't answer. Check that it's awake and online with Codevisor open, then retry."
    case .startingHost:
      "The host Mac didn't answer the request to share its screen. Check that it's awake and online, then retry."
    case .connectingMedia:
      "Couldn't open a media connection to the host Mac. The network or relay between these Macs may be blocking it. Check the connection, then retry."
    case .handshake:
      "The host Mac didn't accept the screen-sharing connection. Retry. If it keeps happening, quit and reopen Codevisor on the host Mac."
    case .waitingForVideo:
      "Connected to the host Mac, but no video arrived. Its screen capture may be stuck. Retry. If it keeps happening, quit and reopen Codevisor on the host Mac."
    }
  }

  public var shortName: String {
    switch self {
    case .reachingHost: "reach"
    case .startingHost: "start"
    case .connectingMedia: "media"
    case .handshake: "handshake"
    case .waitingForVideo: "video"
    }
  }
}
