import Foundation
import Testing
import TranscriptKit

@testable import CodevisorUI

@Suite("Files that page together in a transcript")
struct TranscriptFileGroupsTests {
  @Test("An image pages through the other files of its own message, not its neighbours'")
  func siblingsStayInsideTheMessage() {
    let conversation = [
      Self.user(attachments: ["earlier"]),
      Self.reply(attachments: ["first", "second"]),
      Self.user(attachments: ["later"]),
    ]

    let siblings = TranscriptFileGroups.siblings(of: Self.file("second"), in: conversation)

    #expect(siblings.map(\.source) == [.attachment(fileId: "first"), .attachment(fileId: "second")])
  }

  @Test("A sent message's attachments page together")
  func userAttachmentsPageTogether() {
    let conversation = [Self.user(attachments: ["a", "b", "c"])]

    let siblings = TranscriptFileGroups.siblings(of: Self.file("b"), in: conversation)

    #expect(siblings.map(\.source) == ["a", "b", "c"].map { .attachment(fileId: $0) })
  }

  @Test("A file the transcript does not show pages alone")
  func unknownFilePagesAlone() {
    let stray = Self.file("stray")

    #expect(TranscriptFileGroups.siblings(of: stray, in: [Self.user(attachments: ["a"])]) == [stray])
  }

  private static func file(_ id: String) -> PreviewFile {
    PreviewFile(attachment: attachment(id))
  }

  private static func attachment(_ id: String) -> TranscriptKit.Attachment {
    TranscriptKit.Attachment(fileId: id, name: "\(id).png", mimeType: "image/png", sizeBytes: 1, kind: .image)
  }

  private static func user(attachments: [String]) -> ConversationItem {
    .user(UserMessage(text: "", attachments: attachments.map(attachment)))
  }

  private static func reply(attachments: [String]) -> ConversationItem {
    .assistant(AssistantMessage(turn: AssistantTurn(attachments: attachments.map(attachment))))
  }
}
