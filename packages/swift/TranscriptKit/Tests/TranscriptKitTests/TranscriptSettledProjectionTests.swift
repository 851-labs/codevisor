import CodevisorTestSupport
import Foundation
import Observation
import Testing
@testable import TranscriptKit

@MainActor
struct TranscriptSettledProjectionTests {
  @Test("A projection publishes its rows and stops being pending")
  func publishesRows() async {
    let projection = TranscriptSettledProjection(worker: worker { _ in [Self.row] })
    let request = request(modelRevision: 1)

    #expect(projection.isPending(currentRequest: request))

    projection.submit(request, input: Self.input)
    await publication(of: projection)

    #expect(projection.rows == [Self.row])
    #expect(projection.publication.publishedRequest == request)
    #expect(!projection.isPending(currentRequest: request))
  }

  @Test("Going back to the published request drops a newer projection that is still running")
  func publishedRequestReplacesARunningOne() async {
    let started = TestSignal()
    let release = TestSignal()
    let projection = TranscriptSettledProjection(
      worker: worker { request in
        guard request.key.modelRevision == 2 else { return [Self.row] }

        started.signal()
        await release.wait()
        return []
      })
    let published = request(modelRevision: 1)
    let later = request(modelRevision: 3)
    projection.submit(published, input: Self.input)
    await publication(of: projection)
    let version = projection.rowsVersion

    projection.submit(request(modelRevision: 2), input: Self.input)
    await started.wait()
    projection.submit(published, input: Self.input)
    projection.submit(later, input: Self.input)
    release.signal()
    await publication(of: projection)

    #expect(projection.publication.publishedRequest == later)
    #expect(projection.rowsVersion == version + 1)
    #expect(projection.rows == [Self.row])
  }

  @Test("A different session clears the rows until its own projection arrives")
  func anotherSessionStartsEmpty() async {
    let release = TestSignal()
    let projection = TranscriptSettledProjection(
      worker: worker { request in
        if request.key.sessionID != Self.sessionID { await release.wait() }
        return [Self.row]
      })
    projection.submit(request(modelRevision: 1), input: Self.input)
    await publication(of: projection)
    let other = TranscriptProjectionRequest(
      key: TranscriptProjectionKey(sessionID: UUID(), controllerRevision: 1, modelRevision: 1),
      options: .init(includesConnectingRow: false)
    )

    projection.submit(other, input: Self.input)

    #expect(projection.rows.isEmpty)
    #expect(projection.isPending(currentRequest: other))

    release.signal()
    await publication(of: projection)

    #expect(projection.rows == [Self.row])
    #expect(!projection.isPending(currentRequest: other))
  }

  private func worker(
    _ project: @escaping @Sendable (TranscriptProjectionRequest) async -> [TranscriptPresentationRow]
  ) -> TranscriptSettledProjectionWorker {
    TranscriptSettledProjectionWorker { request, _ in await project(request) }
  }

  private func publication(of projection: TranscriptSettledProjection) async {
    await withCheckedContinuation { continuation in
      withObservationTracking {
        _ = projection.publication
      } onChange: {
        continuation.resume()
      }
    }
  }

  private func request(modelRevision: UInt64) -> TranscriptProjectionRequest {
    TranscriptProjectionRequest(
      key: TranscriptProjectionKey(sessionID: Self.sessionID, controllerRevision: 1, modelRevision: modelRevision),
      options: .init(includesConnectingRow: false)
    )
  }

  nonisolated private static let sessionID = UUID()
  nonisolated private static let row = TranscriptPresentationRow(
    id: .startingAgent, content: .startingAgent, estimatedHeight: 44)

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
