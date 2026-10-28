import ACPKit
import CodevisorProtocol
import Foundation
import TranscriptKit

public struct ServerSessionAutoResume: Decodable, Equatable, Sendable {
  public var state: String?
  public var resumesAt: String?

  public init(state: String? = nil, resumesAt: String? = nil) {
    self.state = state
    self.resumesAt = resumesAt
  }

  public var sessionAutoResume: SessionAutoResume {
    SessionAutoResume(
      state: state.flatMap(SessionAutoResume.State.init(rawValue:)) ?? .scheduled,
      resumesAt: resumesAt.flatMap { try? ServerDateCoding.date(from: $0) }
    )
  }

  static func pending(from payload: JSONValue) -> SessionAutoResume? {
    guard let state = payload["state"]?.stringValue, SessionAutoResume.State(rawValue: state) != nil else {
      return nil
    }
    return ServerSessionAutoResume(state: state, resumesAt: payload["resumesAt"]?.stringValue).sessionAutoResume
  }
}
