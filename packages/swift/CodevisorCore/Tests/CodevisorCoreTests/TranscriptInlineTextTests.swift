import ACPKit
import CodevisorTestSupport
import Foundation
import Testing
@testable import CodevisorCore

@MainActor
struct TranscriptInlineTextTests {
  @Test func visibleRangeFetchesOnlyEightBlocksAndPreservesEveryCharacter() async throws {
    let page = try page(position: 16)
    var requests: [Int] = []
    let result = try await TranscriptInlineTextContent.load(page) { position in
      requests.append(position)
      return try block(position: position, next: position + 1, text: "😀" + String(position), prefix: "```swift\n")
    }
    #expect(requests == Array(16..<24))
    #expect(result.text == (16..<24).map { "😀" + String($0) }.joined())
    #expect(result.markdownPrefix == "```swift\n")
  }

  @Test func finalRangeStopsAtTheEndInsteadOfReadingTheWholeDocument() async throws {
    var requests: [Int] = []
    let result = try await TranscriptInlineTextContent.load(page(position: 8)) { position in
      requests.append(position)
      return try block(position: position, next: position == 9 ? nil : position + 1, text: "part\(position)")
    }
    #expect(requests == [8, 9])
    #expect(result.text == "part8part9")
  }

  @Test func aReplacedDocumentCannotMixGenerationsInOneInlineRange() async throws {
    await #expect(throws: CodevisorServerClientError.self) {
      try await TranscriptInlineTextContent.load(page(position: 0)) { position in
        try block(position: position, next: position + 1, text: "part", revision: position == 0 ? 1 : 2)
      }
    }
  }

  @Test func explicitCopyReadsBeyondTheDisplayWindowWithoutCopyingSyntheticMarkdown() async throws {
    var requests: [Int] = []
    let result = try await TranscriptInlineTextContent.load(page(position: 0), maxBlocks: .max) { position in
      requests.append(position)
      return try block(
        position: position, next: position == 11 ? nil : position + 1,
        text: "part\(position) ", prefix: "```swift\n")
    }
    #expect(requests == Array(0..<12))
    #expect(result.text == (0..<12).map { "part\($0) " }.joined())
  }

  @Test func liveRevisionsCoalesceAndReuseCompletedBlocks() async throws {
    let model = TranscriptInlineTextModel()
    defer { model.cancel() }
    var first = try page(position: 0)
    first.resource.fields[0].revision = 1
    first.resource.fields[0].pageCount = 8
    var latest = first
    latest.resource.fields[0].revision = 3
    let started = TestSignal()
    let (gate, release) = AsyncStream.makeStream(of: Void.self)
    defer { release.finish() }
    var requests: [(Int, Int)] = []
    let fetch: @MainActor (ToolDetailResource, Int) async throws -> ServerTranscriptBodyPage = { resource, position in
      let revision = resource.fields[0].revision
      requests.append((position, revision))
      if requests.count == 1 {
        started.signal()
        for await _ in gate { break }
      }
      return try block(
        position: position, next: position == 7 ? nil : position + 1,
        text: position == 7 ? "tail\(revision)" : "fixed", revision: 1)
    }
    model.load(first, fetch: fetch)
    await started.wait()
    model.load(latest, fetch: fetch)
    #expect(requests.count == 1)
    release.finish()
    await awaitObserved { model.content?.text.hasSuffix("tail3") == true }
    #expect(requests.map { $0.0 } == Array(0..<8) + [7])
    #expect(model.errorMessage == nil)
    model.cancel()
    #expect(model.content == nil)
  }

  @Test func aCodeLineCrossingTheDisplayBoundaryAppearsWholeExactlyOnce() async throws {
    var first = try page(position: 0)
    first.resource.fields[0].pageCount = 9
    var next = first
    next.position = 8
    let leading = try await TranscriptInlineTextContent.load(first) { position in
      try block(position: position, next: position + 1, text: position == 7 ? "before\nlet value = " : "line\n")
    }
    let trailing = try await TranscriptInlineTextContent.load(next) { position in
      var result = try block(position: position, next: nil, text: "123\nAfter\n")
      result.leadingText = "let value = "
      return result
    }
    #expect(leading.displayText + trailing.displayText == leading.text + trailing.text)
    #expect(trailing.displayText.hasPrefix("let value = 123\n"))
  }

  private func page(position: Int) throws -> TranscriptInlineTextPage {
    let resource = try JSONDecoder().decode(
      ToolDetailResource.self,
      from: Data(
        """
        {"itemId":"item","entryKey":"message","fields":[{"name":"text","encoding":"text","revision":1,"sizeBytes":4000000,"pageCount":245}]}
        """.utf8))
    return TranscriptInlineTextPage(resource: resource, position: position)
  }

  private func block(
    position: Int, next: Int?, text: String, prefix: String = "", revision: Int = 1
  ) throws
    -> ServerTranscriptBodyPage
  {
    var object: [String: Any] = [
      "position": position, "text": text, "revision": revision, "encoding": "text", "markdownPrefix": prefix,
    ]
    if let next { object["nextPosition"] = next }
    return try JSONDecoder().decode(ServerTranscriptBodyPage.self, from: JSONSerialization.data(withJSONObject: object))
  }
}
