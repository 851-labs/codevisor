import Foundation
import Testing
import TranscriptKit

@testable import CodevisorCore

@MainActor
@Suite("Add to Chat composer focus")
struct SessionControllerAddToChatTests {
  private func withController(_ body: (SessionController) -> Void) {
    let files = ComposerAttachmentFileStore.temporary()
    defer { try? FileManager.default.removeItem(at: files.root) }
    let controller = SessionController(
      project: Project.fromFolder(URL(fileURLWithPath: "/tmp/add-to-chat-tests")),
      configCache: ConfigOptionCache(store: InMemoryStore()),
      attachmentFiles: files
    )
    body(controller)
  }

  private func quote(_ text: String) -> TranscriptQuote {
    TranscriptQuote(text: text, messageID: UUID().uuidString, role: .assistant)
  }

  private func image(_ name: String) -> PreviewFile {
    PreviewFile(source: .pendingCapture("/tmp/\(name)"), name: name, mimeType: "image/png", kind: .image)
  }

  @Test("Adding a quote or an image asks the composer to take focus")
  func addingAsksForFocus() {
    withController { controller in
      controller.addQuote(quote("First"))
      #expect(controller.addToChatSignal == 1)

      controller.composerText = "Already typing"
      controller.addQuote(quote("Second"))
      #expect(controller.addToChatSignal == 2)

      controller.addTranscriptImage(image("Chart.png"))
      #expect(controller.addToChatSignal == 3)
    }
  }

  @Test("A blank quote or an image past the limit leaves focus alone")
  func nothingAddedLeavesFocusAlone() {
    withController { controller in
      for index in 1...ComposerAttachments.maxAttachments {
        controller.addTranscriptImage(image("Image \(index).png"))
      }
      let requests = controller.addToChatSignal

      controller.addQuote(quote("  \n "))
      controller.addTranscriptImage(image("Over the limit.png"))

      #expect(controller.addToChatSignal == requests)
    }
  }

  @Test("An added quote waits for the composer, then is sent and saved where it sits")
  func addedQuoteTravelsInline() {
    withController { controller in
      controller.composerText = "compare"
      controller.addQuote(quote("  Use a mutex.\n"))
      let pending = controller.pendingQuoteInsertions
      #expect(pending.map(\.text) == ["Use a mutex."])

      let edit = TranscriptQuotedPromptEdit.insertingQuotes(pending, into: controller.composerPrompt, at: 7)
      controller.composerPrompt = edit.applied(to: controller.composerPrompt)
      controller.finishQuoteInsertions(Set(pending.map(\.id)))
      controller.composerText += "please"

      #expect(controller.pendingQuoteInsertions.isEmpty)
      #expect(controller.composerPromptText.hasPrefix("compare <codevisor-quote role=\"assistant\""))
      #expect(controller.composerPromptText.hasSuffix(">Use a mutex.</codevisor-quote> please"))

      let saved = controller.draftSnapshot()
      controller.composerPrompt = TranscriptQuotedPrompt()
      controller.restoreDraft(saved)
      #expect(controller.composerQuotes.map(\.text) == ["Use a mutex."])
      #expect(controller.composerText == "compare \(TranscriptQuotedPrompt.quoteMarker) please")
    }
  }
}
