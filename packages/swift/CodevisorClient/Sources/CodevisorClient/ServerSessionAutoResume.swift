import ACPKit
import CodevisorProtocol
import Foundation
import TranscriptKit

public struct ServerSessionAutoResume: Decodable, Equatable, Sendable {
  public var resumesAt: String?

  public init(resumesAt: String? = nil) {
    self.resumesAt = resumesAt
  }

  public var sessionAutoResume: SessionAutoResume {
    SessionAutoResume(resumesAt: resumesAt.flatMap { try? ServerDateCoding.date(from: $0) })
  }

  static func pending(from payload: JSONValue) -> SessionAutoResume? {
    guard payload["state"]?.stringValue == "scheduled" else { return nil }
    return ServerSessionAutoResume(resumesAt: payload["resumesAt"]?.stringValue).sessionAutoResume
  }
}
