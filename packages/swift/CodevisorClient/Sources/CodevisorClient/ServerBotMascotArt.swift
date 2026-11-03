import Foundation

public struct ServerBotMascotArt: Hashable, Sendable {
  public enum Kind: Hashable, Sendable {
    case portrait
    case figure
    case loop(ServerBotMascotLoop)
  }

  private static let revision = "3"

  public var mascot: ServerBotMascot
  public var kind: Kind

  public init(_ mascot: ServerBotMascot, _ kind: Kind) {
    self.mascot = mascot
    self.kind = kind
  }

  var path: String {
    var query = URLComponents()
    query.queryItems = mascot.queryItems + kindQueryItems + [URLQueryItem(name: "revision", value: Self.revision)]
    return "\(route)?\(query.percentEncodedQuery ?? "")"
  }

  private var route: String {
    switch kind {
    case .portrait, .figure: "/v1/bot-mascots/image"
    case .loop: "/v1/bot-mascots/animation"
    }
  }

  private var kindQueryItems: [URLQueryItem] {
    switch kind {
    case .portrait: []
    case .figure: [URLQueryItem(name: "framing", value: "figure")]
    case let .loop(loop): [URLQueryItem(name: "loop", value: loop.rawValue)]
    }
  }
}

public enum ServerBotMascotLoop: String, Hashable, Sendable {
  case idle
  case working
}
