import ACPKit
import Foundation

public struct TranscriptInlineTextContent: Sendable {
  public let text: String
  public let displayText: String
  public let markdownPrefix: String
}

extension TranscriptInlineTextContent {
  @MainActor
  static func load(
    _ page: TranscriptInlineTextPage, maxBlocks: Int = TranscriptInlineTextPage.blocksPerPage,
    fetch: (Int) async throws -> ServerTranscriptBodyPage
  ) async throws -> Self {
    var text = ""
    var markdownPrefix = ""
    var leadingText = ""
    var position = page.position
    var generation: Int?
    for _ in 0..<maxBlocks {
      try Task.checkCancellation()
      let block = try await fetch(position)
      if position == page.position {
        markdownPrefix = block.markdownPrefix ?? ""
        leadingText = block.leadingText ?? ""
      }
      if let generation, generation != block.revision { throw CodevisorServerClientError.invalidResponse }
      generation = block.revision
      text += block.text
      guard let next = block.nextPosition else { break }
      position = next
    }
    try Task.checkCancellation()
    var displayText = leadingText + text
    // Move a short boundary line wholly into the following virtual row. The
    // server supplies at most 1,024 UTF-16 units of line context; huge single
    // lines stay split and bounded. Original text used by Copy is untouched.
    if maxBlocks == TranscriptInlineTextPage.blocksPerPage, !page.isLast,
      let newline = displayText.lastIndex(of: "\n")
    {
      let end = displayText.index(after: newline)
      if displayText[end...].utf16.count <= 1_024 { displayText = String(displayText[..<end]) }
    }
    return TranscriptInlineTextContent(text: text, displayText: displayText, markdownPrefix: markdownPrefix)
  }
}

extension SessionController {
  /// Copy is an explicit request for the complete original text. Display
  /// loading remains limited to mounted ranges.
  public func completeTranscriptText(resource: ToolDetailResource) async throws -> String {
    try await TranscriptInlineTextContent.load(.init(resource: resource, position: 0), maxBlocks: .max) { position in
      try await transcriptBodyPage(resource: resource, field: "text", position: position)
    }.text
  }

  /// Fetch at most eight permanent blocks for a mounted native row.
  public func inlineTranscriptText(_ page: TranscriptInlineTextPage) async throws -> TranscriptInlineTextContent {
    try await TranscriptInlineTextContent.load(page) { position in
      try await transcriptBodyPage(resource: page.resource, field: "text", position: position)
    }
  }
}
