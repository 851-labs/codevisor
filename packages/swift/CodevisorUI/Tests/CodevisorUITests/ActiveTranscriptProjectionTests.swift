import CodevisorCore
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorUI

@MainActor
@Suite("A chat's live transcript rows")
struct ActiveTranscriptProjectionTests {
  private let controller = SessionController(
    project: .fromFolder(URL(fileURLWithPath: "/tmp/active-transcript-projection-tests")),
    configCache: ConfigOptionCache(store: InMemoryStore()))
  private let row = TranscriptPresentationRow(id: .startingAgent, content: .startingAgent, estimatedHeight: 44)

  @Test("Rows keep publishing while one of two views still shows the chat")
  func publishesWhileAnyViewObserves() {
    let projection = ActiveTranscriptProjection()
    let leaving = UUID()
    projection.observeFrames(of: controller.presentationClock, for: leaving)
    projection.observeFrames(of: controller.presentationClock, for: UUID())

    projection.stopObservingFrames(for: leaving)
    present([row], in: projection)

    #expect(projection.rows == [row])
  }

  @Test("Rows stop publishing once the last view has left")
  func stopsWhenNoViewObserves() {
    let projection = ActiveTranscriptProjection()
    let view = UUID()
    projection.observeFrames(of: controller.presentationClock, for: view)

    projection.stopObservingFrames(for: view)
    present([row], in: projection)

    #expect(projection.rows.isEmpty)
  }

  @Test("Presenting the same rows again is not a new version")
  func sameRowsKeepTheirVersion() {
    let projection = ActiveTranscriptProjection()
    projection.observeFrames(of: controller.presentationClock, for: UUID())
    present([row], in: projection)
    let version = projection.rowsVersion

    present([row], in: projection)

    #expect(projection.rowsVersion == version)

    present([], in: projection)

    #expect(projection.rowsVersion == version + 1)
  }

  private func present(_ rows: [TranscriptPresentationRow], in projection: ActiveTranscriptProjection) {
    let key = ActiveTranscriptProjectionKey(controller: controller, projectedItem: nil)
    projection.staging.latestKey = key
    projection.staging.ready = ActiveTranscriptReadyProjection(key: key, rows: rows)
    controller.presentationClock.requestFrame()
  }
}
