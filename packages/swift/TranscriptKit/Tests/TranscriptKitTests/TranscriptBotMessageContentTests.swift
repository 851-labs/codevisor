import Foundation
import MarkdownCore
import Testing

@testable import TranscriptKit

struct TranscriptBotMessageContentTests {
  private func content(_ text: String) -> TranscriptBotMessageContent {
    TranscriptBotMessageContent(TranscriptBotMessage(id: "m", sender: .bot, text: text, attachments: []))
  }

  @Test("Bullet-character lines render as a list under their lead-in line")
  func bulletCharacterList() {
    let text =
      "Coming up:\n• Chrome install card put back how it was\n• Send failures in normal chats: shots\n"
      + "• The double \"Working for\" fix: shots"
    let message = content(text)
    #expect(message.text == text)
    #expect(
      MarkdownParser().parse(message.markdown) == [
        .paragraph("Coming up:"),
        .bulletList([
          "Chrome install card put back how it was", "Send failures in normal chats: shots",
          "The double \"Working for\" fix: shots",
        ]),
      ])
  }

  @Test("Single newlines stay line breaks", arguments: ["\n", "\r\n"])
  func singleNewlines(newline: String) {
    let blocks = MarkdownParser().parse(content("First line\(newline)Second line\n\nNext").markdown)
    #expect(
      blocks == [
        .paragraph(MarkdownText(spans: [.text("First line"), .hardBreak, .text("Second line")])),
        .paragraph("Next"),
      ])
  }

  @Test("Fenced code keeps its lines and bullets verbatim")
  func fencedCode() {
    let code = "```\n• not a list\nsecond\n```"
    #expect(content(code).markdown == code)
  }

  @Test("Cached content is replaced when a message's text changes")
  func cacheFollowsEdits() {
    let cache = TranscriptBotMessageContentCache()
    let original = TranscriptBotMessage(id: "m", sender: .bot, text: "One")
    #expect(cache.content(for: original).blocks == [.paragraph("One")])
    let edited = TranscriptBotMessage(id: "m", sender: .bot, text: "Two")
    #expect(cache.content(for: edited).blocks == [.paragraph("Two")])
  }
}
