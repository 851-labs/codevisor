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

  @Test("Removing a quote, a blank quote, or an image past the limit leaves focus alone")
  func nothingAddedLeavesFocusAlone() {
    withController { controller in
      let kept = quote("Kept")
      controller.addQuote(kept)
      for index in 1...ComposerAttachments.maxAttachments {
        controller.addTranscriptImage(image("Image \(index).png"))
      }
      let requests = controller.addToChatSignal

      controller.removeQuote(id: kept.id)
      controller.addQuote(quote("  \n "))
      controller.addTranscriptImage(image("Over the limit.png"))

      #expect(controller.addToChatSignal == requests)
    }
  }
}
