import Foundation

public enum ServerAddress: Sendable, Equatable {
  case fixed(URL)
  case localServer(LocalServerEndpoint)

  public var url: URL {
    switch self {
    case let .fixed(url): url
    case let .localServer(endpoint): endpoint.baseURL
    }
  }

  public static func == (lhs: ServerAddress, rhs: ServerAddress) -> Bool {
    switch (lhs, rhs) {
    case let (.fixed(left), .fixed(right)): left == right
    case let (.localServer(left), .localServer(right)): left === right
    default: false
    }
  }
}
