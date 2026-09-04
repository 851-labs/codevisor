import ACPKit
import Foundation
import Testing
@testable import TranscriptKit

@Suite("Generated image delivery")
struct GeneratedImageTests {
  private func completedImage(parent: String? = nil) -> ToolCallUpdate {
    ToolCallUpdate(
      toolCallId: "image-1", kind: .imageGeneration, status: .completed,
      rawOutput: .object([
        "attachment": .object([
          "fileId": .string("file-1"), "name": .string("Generated image.png"),
          "mimeType": .string("image/png"), "sizeBytes": .number(42), "kind": .string("image"),
        ])
      ]),
      parentToolCallId: parent
    )
  }

  @Test("Progress is visible outside the worked section and completion delivers the image once")
  func lifecycle() {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(
      .toolCall(
        ToolCall(toolCallId: "image-1", title: "Generating image", kind: .imageGeneration, status: .inProgress)),
      to: &turn)
    #expect(turn.generatedImageActivity.count == 1)
    #expect(turn.workedItems.isEmpty)
    TranscriptReducer.apply(.toolCallUpdate(completedImage()), to: &turn)
    TranscriptReducer.apply(.toolCallUpdate(completedImage()), to: &turn)
    #expect(turn.generatedImageActivity.isEmpty)
    #expect(turn.attachments.count == 1)
    #expect(turn.attachments.first?.fileId == "file-1")
    #expect(turn.finalText == nil)
    let segments = assistantMarkdownSegments("", attachments: turn.attachments)
    #expect(segments.count == 1)
    #expect(
      assistantMarkdownSegments("![Image](https://attachments.codevisor.invalid/file-1)", attachments: turn.attachments)
        .count == 1)
  }

  @Test("A subagent image stays attributed to its own thread")
  func subagent() {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(.toolCallUpdate(completedImage(parent: "child")), to: &turn)
    #expect(turn.attachments.isEmpty)
    #expect(turn.subagents["child"]?.entries.count == 1)
  }

  @Test("Image-only turns project progress and persisted previews without final text")
  func imageOnlyRows() {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(
      .toolCall(
        ToolCall(toolCallId: "image-1", title: "Generating image", kind: .imageGeneration, status: .inProgress)),
      to: &turn)
    let pending = AssistantMessage(turn: turn)
    #expect(
      TranscriptActiveRowProjection.rows(for: .assistant(pending)).contains { row in
        if case .assistantResult = row.content { return true }
        return false
      })
    TranscriptReducer.apply(.toolCallUpdate(completedImage()), to: &turn)
    // History initially loads only the attachments, before worked details.
    turn.entries = []
    turn.isGenerating = false
    let completed = AssistantMessage(turn: turn)
    let rows = TranscriptActiveRowProjection.rows(for: .assistant(completed))
    #expect(
      rows.filter { row in
        if case .assistantAttachment = row.content { return true }
        return false
      }.count == 1)
  }

  @Test("Failed and interrupted generations remain visible")
  func failed() {
    var turn = AssistantTurn(isGenerating: true)
    TranscriptReducer.apply(
      .toolCall(
        ToolCall(toolCallId: "image-1", title: "Generating image", kind: .imageGeneration, status: .inProgress)),
      to: &turn)
    TranscriptReducer.apply(.toolCallUpdate(ToolCallUpdate(toolCallId: "image-1", status: .failed)), to: &turn)
    #expect(turn.generatedImageActivity.first?.status == .failed)
    #expect(turn.attachments.isEmpty)
  }
}
