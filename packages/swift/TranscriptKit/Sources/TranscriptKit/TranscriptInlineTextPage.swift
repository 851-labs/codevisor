import ACPKit
import Foundation

/// A small run of permanent text blocks, mounted by the transcript virtualizer.
/// Only visible runs fetch their text; row descriptors contain no full bodies.
public struct TranscriptInlineTextPage: Equatable, Sendable {
  public static let blocksPerPage = 8
  public var resource: ToolDetailResource
  public var position: Int
  public var preview: String
  public var userMessage: UserMessage?
  public var isPlan: Bool

  public init(
    resource: ToolDetailResource, position: Int, preview: String = "",
    userMessage: UserMessage? = nil, isPlan: Bool = false
  ) {
    self.resource = resource
    self.position = position
    self.preview = preview
    self.userMessage = userMessage
    self.isPlan = isPlan
  }

  public static func positions(for resource: ToolDetailResource) -> [Int] {
    let count = resource.fields.first(where: { $0.name == "text" })?.pageCount ?? 0
    return Array(stride(from: 0, to: max(1, count), by: blocksPerPage))
  }

  public static func == (lhs: Self, rhs: Self) -> Bool {
    lhs.resource.itemId == rhs.resource.itemId && lhs.resource.entryKey == rhs.resource.entryKey
      && lhs.position == rhs.position && lhs.generation == rhs.generation
      && lhs.isLast == rhs.isLast && (!lhs.isLast || lhs.revision == rhs.revision)
      && lhs.preview == rhs.preview && lhs.userMessage == rhs.userMessage && lhs.isPlan == rhs.isPlan
  }

  public var displayRevision: Int { isLast ? revision : generation }

  public var generation: Int { resource.fields.first(where: { $0.name == "text" })?.generation ?? 0 }

  public var revision: Int { resource.fields.first(where: { $0.name == "text" })?.revision ?? 0 }
  public var isLast: Bool {
    position + Self.blocksPerPage >= (resource.fields.first(where: { $0.name == "text" })?.pageCount ?? 1)
  }
}
