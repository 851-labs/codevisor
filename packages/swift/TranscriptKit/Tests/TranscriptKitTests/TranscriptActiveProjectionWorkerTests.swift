import CodevisorTestSupport
import Foundation
import Synchronization
import Testing
@testable import TranscriptKit

@MainActor
struct TranscriptActiveProjectionWorkerTests {
  @Test("Projection keeps one in-flight parse and replaces the waiting snapshot")
  func latestPendingSnapshotWins() async {
    let started = TestSignal()
    let release = TestSignal()
    let projectedMarkdown = Mutex<[String]>([])
    let worker = TranscriptActiveProjectionWorker { item, _ in
      let markdown = Self.markdown(in: item)
      projectedMarkdown.withLock { $0.append(markdown) }
      if markdown == "first" {
        started.signal()
        await release.wait()
      }
      return []
    }

    let firstPublished = Mutex(false)
    worker.submit(request(revision: 1, markdown: "first")) { output in
      #expect(output.request.revision == 1)
      firstPublished.withLock { $0 = true }
    }
    await started.wait()
    worker.submit(request(revision: 2, markdown: "second")) { _ in
      Issue.record("A replaced waiting projection must not publish")
    }

    let publishedRevision = await withCheckedContinuation { continuation in
      worker.submit(request(revision: 3, markdown: "third")) { output in
        continuation.resume(returning: output.request.revision)
      }
      release.signal()
    }

    #expect(firstPublished.withLock { $0 })
    #expect(publishedRevision == 3)
    #expect(projectedMarkdown.withLock { $0 } == ["first", "third"])
  }

  private func request(revision: UInt64, markdown: String) -> TranscriptActiveProjectionWorker.Request {
    let message = AssistantMessage(
      turn: AssistantTurn(
        entries: [.text(id: "answer", markdown: markdown)],
        isGenerating: true
      )
    )
    return .init(
      revision: revision,
      projectedID: message.id,
      item: .assistant(message),
      waitingOnBackgroundTask: nil
    )
  }

  nonisolated private static func markdown(in item: ConversationItem) -> String {
    guard case let .assistant(message) = item,
      case let .text(_, markdown)? = message.turn.entries.first
    else { return "" }
    return markdown
  }
}
