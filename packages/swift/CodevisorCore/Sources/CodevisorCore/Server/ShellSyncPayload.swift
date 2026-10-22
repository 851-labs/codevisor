import ACPKit
import Foundation

nonisolated enum ShellSyncPayload {
  static func decoded<Payload: Decodable>(_ type: Payload.Type, from payload: JSONValue) -> Payload? {
    try? decode(type, from: payload)
  }

  @concurrent
  static func navigationDelta(_ payload: JSONValue) async throws -> ServerNavigationDelta {
    try decode(ServerNavigationDelta.self, from: payload)
  }

  private static func decode<Payload: Decodable>(_ type: Payload.Type, from payload: JSONValue) throws -> Payload {
    try JSONDecoder().decode(type, from: JSONEncoder().encode(payload))
  }
}
