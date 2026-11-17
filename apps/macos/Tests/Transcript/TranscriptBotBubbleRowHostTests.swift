import AppKit
import StreamMarkdown
import Testing
import TranscriptKit
@testable import TranscriptSurface

@MainActor
@Suite("Bot bubble row width")
struct TranscriptBotBubbleRowHostTests {
  private let rowWidth: CGFloat = 480
  private let wideTable = """
    | Day | Meal | Calories | Protein | Notes |
    |---|---|---|---|---|
    | 11/16 | Breakfast | 110 kcal (2,390 to go) | 2 g (108 to go) | logged from the daily health sync after breakfast |
    """
  private let longText = String(repeating: "A long bot reply that wraps across the whole row. ", count: 6)

  @Test("A table bubble that outgrows the row reaches as far as a text bubble does")
  func tableBubbleReachesTextBubbleEdge() throws {
    let table = try bubbleFrame(for: wideTable, expecting: .table)
    let text = try bubbleFrame(for: longText, expecting: .text)

    #expect(table.maxX == text.maxX)
  }

  @Test("A click inside a table bubble reaches the table, not the bubble behind it")
  func clicksReachTableInsideBubble() throws {
    let host = try mountedHost(for: wideTable, expecting: .table)
    let bubble = try #require(host.subviews.first { $0 is TranscriptBubbleBackgroundView })
    host.setFrameSize(NSSize(width: rowWidth, height: bubble.frame.maxY))
    host.layoutSubtreeIfNeeded()

    let hit = try #require(host.hitTest(NSPoint(x: bubble.frame.midX, y: bubble.frame.midY)))

    #expect(sequence(first: hit, next: \.superview).contains { $0 is SettledMarkdownView })
  }

  private func bubbleFrame(for text: String, expecting style: TranscriptBotPartStyle) throws -> NSRect {
    let host = try mountedHost(for: text, expecting: style)
    return try #require(host.subviews.first { $0 is TranscriptBubbleBackgroundView }).frame
  }

  private func mountedHost(
    for text: String, expecting style: TranscriptBotPartStyle
  ) throws -> TranscriptBotBubbleRowHost {
    let message = TranscriptBotMessage(id: UUID().uuidString, sender: .bot, text: text, sentAt: .distantPast)
    let content = TranscriptBotMessageContent(message)
    #expect(content.partStyle == style)
    let layout = try #require(TranscriptBotBubbleLayout.forPart(content.partStyle))
    let host = TranscriptBotBubbleRowHost(frame: NSRect(x: 0, y: 0, width: rowWidth, height: 16))
    host.setContent(
      content, messageID: message.id, layout: layout, style: TranscriptMarkdownRowStyle(markdown: .default),
      linkAction: nil, imageLoader: .remote, knownHeight: nil)
    return host
  }
}
