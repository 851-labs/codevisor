import ACPKit
import Foundation
import TranscriptKit

actor ServerTranscriptContent {
  enum LoadError: Error { case changed(ToolDetailResource) }

  private struct CachedField {
    let metadata: ToolDetailResource.Field
    let text: String
  }

  private let transport: ServerSessionTransport
  private var cache: [String: CachedField] = [:]

  init(transport: ServerSessionTransport) { self.transport = transport }

  func field(_ field: ToolDetailResource.Field, resource: ToolDetailResource) async throws -> String {
    let key = "\(resource.itemId):\(resource.entryKey):\(field.name)"
    if let cached = cache[key], cached.metadata == field { return cached.text }
    let expectedRevision = field.generation ?? field.revision
    let transport = self.transport
    var blocks: [ServerTranscriptBodyPage]
    if let count = field.pageCount {
      blocks = try await withThrowingTaskGroup(of: ServerTranscriptBodyPage.self) { group in
        var next = 0
        func enqueue(_ position: Int) {
          group.addTask {
            try Task.checkCancellation()
            return try await Self.block(transport: transport, resource: resource, field: field.name, position: position)
          }
        }
        while next < min(8, count) { enqueue(next); next += 1 }
        var result: [ServerTranscriptBodyPage] = []
        while let block = try await group.next() {
          guard block.revision == expectedRevision else { throw LoadError.changed(resource) }
          result.append(block)
          if next < count { enqueue(next); next += 1 }
        }
        return result.sorted { $0.position < $1.position }
      }
    } else {
      blocks = []
      var position = 0
      repeat {
        try Task.checkCancellation()
        let block = try await Self.block(
          transport: transport, resource: resource, field: field.name, position: position)
        guard block.revision == expectedRevision else { throw LoadError.changed(resource) }
        blocks.append(block)
        guard let next = block.nextPosition else { break }
        guard next > position else { throw CodevisorServerClientError.invalidResponse }
        position = next
      } while true
    }
    try Task.checkCancellation()
    var text = blocks.map(\.text).joined()
    if field.name == "text", field.generation != nil {
      let length = field.sizeBytes / 2
      guard text.utf16.count >= length else { throw LoadError.changed(resource) }
      text = (text as NSString).substring(to: length)
    }
    cache[key] = CachedField(metadata: field, text: text)
    return text
  }

  private static func block(
    transport: ServerSessionTransport, resource: ToolDetailResource, field: String, position: Int
  ) async throws -> ServerTranscriptBodyPage {
    do {
      return try await transport.transcriptBodyPage(resource: resource, field: field, position: position)
    } catch CodevisorServerClientError.httpStatus(404, _) {
      throw LoadError.changed(resource)
    }
  }

  func payload(_ payload: JSONValue) async throws -> JSONValue {
    guard case var .object(values) = payload, let encoded = values["detailResource"] else { return payload }
    let resource = try JSONDecoder().decode(ToolDetailResource.self, from: JSONEncoder().encode(encoded))
    let update = values["sessionUpdate"]?.stringValue
    if isCompleteInlinePatch(values, update: update) {
      values.removeValue(forKey: "detailResource")
      return .object(values)
    }
    for metadata in resource.fields {
      let text = try await field(metadata, resource: resource)
      try installField(text, metadata: metadata, update: update, into: &values)
    }
    values.removeValue(forKey: "detailResource")
    return .object(values)
  }

  private func isCompleteInlinePatch(_ values: [String: JSONValue], update: String?) -> Bool {
    guard update == "agent_message_patch",
      let text = values["text"]?.stringValue,
      let offset = values["offset"]?.intValue, let total = values["totalLength"]?.intValue
    else { return false }
    return offset + text.utf16.count >= total
  }

  private func installField(
    _ text: String, metadata: ToolDetailResource.Field, update: String?, into values: inout [String: JSONValue]
  ) throws {
    if update == "agent_message_patch", metadata.name == "text" {
      values["text"] = .string(text)
      values["offset"] = .number(0)
    } else if update == "plan_document", metadata.name == "text" {
      values["markdown"] = .string(text)
    } else {
      values[metadata.name] =
        metadata.encoding == "json"
        ? try JSONDecoder().decode(JSONValue.self, from: Data(text.utf8)) : .string(text)
    }
  }
}
