import CodevisorTestSupport
import Foundation
import Synchronization
import Testing
@testable import TranscriptKit

@MainActor
struct TranscriptSettledProjectionWorkerTests {
  @Test("Newer requests let the running projection publish, then only the latest waiting one runs")
  func runningProjectionPublishesBeforeTheLatestRequest() async {
    let started = TestSignal()
    let release = TestSignal()
    let projectedRevisions = Mutex<[UInt64]>([])
    let worker = TranscriptSettledProjectionWorker { request, _ in
      projectedRevisions.withLock { $0.append(request.key.modelRevision) }
      if request.key.modelRevision == 1 {
        started.signal()
        await release.wait()
      }
      return []
    }

    let published = Mutex<[UInt64]>([])
    worker.submit(request(modelRevision: 1), input: Self.input) { output in
      published.withLock { $0.append(output.request.key.modelRevision) }
    }
    await started.wait()
    worker.submit(request(modelRevision: 2), input: Self.input) { _ in
      Issue.record("A replaced waiting projection must not publish")
    }

    let latest = await withCheckedContinuation { continuation in
      worker.submit(request(modelRevision: 3), input: Self.input) { output in
        continuation.resume(returning: output.request.key.modelRevision)
      }
      release.signal()
    }

    #expect(published.withLock { $0 } == [1])
    #expect(latest == 3)
    #expect(projectedRevisions.withLock { $0 } == [1, 3])
  }

  private func request(modelRevision: UInt64) -> TranscriptProjectionRequest {
    TranscriptProjectionRequest(
      key: TranscriptProjectionKey(sessionID: Self.sessionID, controllerRevision: 1, modelRevision: modelRevision),
      options: .init(includesConnectingRow: false)
    )
  }

  private static let sessionID = UUID()

  private static let input = TranscriptProjectionInput(
    settledConversation: [],
    pendingUserMessage: nil,
    activeItem: nil,
    setupPhases: [],
    waitingBackgroundTaskDescription: nil,
    waitingHarnessUpdateName: nil,
    isLoadingInitialHistory: false,
    serverWaitMessage: nil,
    sessionErrorMessage: nil,
    status: .idle,
    activityMessage: nil,
    botConversation: nil,
    outgoingMessages: [],
    deliveries: [:]
  )
}
