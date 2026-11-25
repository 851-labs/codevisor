import Foundation

struct TranscriptPagePayload: Sendable {
  struct Item: Sendable {
    let id: String
    let sequence: Int
    let payload: Data
    let attachments: [ServerAttachmentRef]
  }

  let head: Data
  let items: [Item]
  let eventCursor: Int
  let nextBefore: String?
  let runtime: Data?

  var oldest: Item? { items.min { $0.sequence < $1.sequence } }

  var newestSequence: Int { items.map(\.sequence).max() ?? 0 }

  static func opened(_ data: Data) throws -> TranscriptPagePayload {
    let response = try object(from: data)
    guard let transcript = response["transcript"] as? [String: Any] else { throw ParseError.missing("transcript") }

    let runtime = try response["runtime"].map { try JSONSerialization.data(withJSONObject: $0) }
    return try page(transcript, runtime: runtime)
  }

  static func page(_ data: Data) throws -> TranscriptPagePayload {
    try page(try object(from: data), runtime: nil)
  }

  static func assemble(head: Data, items: [Data], nextBefore: String?) throws -> Data {
    var page = try object(from: head)
    page["items"] = try items.map { try JSONSerialization.jsonObject(with: $0) }
    page["hasMore"] = nextBefore != nil
    page["nextBefore"] = nextBefore
    return try JSONSerialization.data(withJSONObject: page)
  }

  enum ParseError: Error {
    case missing(String)
  }

  private static func page(_ page: [String: Any], runtime: Data?) throws -> TranscriptPagePayload {
    guard let rawItems = page["items"] as? [[String: Any]] else { throw ParseError.missing("items") }
    guard let eventCursor = page["eventCursor"] as? Int else { throw ParseError.missing("eventCursor") }

    var head = page
    head["items"] = nil
    return TranscriptPagePayload(
      head: try JSONSerialization.data(withJSONObject: head),
      items: try rawItems.map(item),
      eventCursor: eventCursor,
      nextBefore: page["hasMore"] as? Bool == true ? page["nextBefore"] as? String : nil,
      runtime: runtime)
  }

  private static func item(_ raw: [String: Any]) throws -> Item {
    guard let id = raw["id"] as? String else { throw ParseError.missing("item id") }
    guard let sequence = raw["sequence"] as? Int else { throw ParseError.missing("item sequence") }

    let payload = try JSONSerialization.data(withJSONObject: raw)
    return Item(id: id, sequence: sequence, payload: payload, attachments: attachments(in: raw))
  }

  private static func attachments(in raw: [String: Any]) -> [ServerAttachmentRef] {
    guard let list = raw["attachments"], let data = try? JSONSerialization.data(withJSONObject: list) else { return [] }
    return (try? JSONDecoder().decode([ServerAttachmentRef].self, from: data)) ?? []
  }

  private static func object(from data: Data) throws -> [String: Any] {
    guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      throw ParseError.missing("object")
    }
    return object
  }
}
