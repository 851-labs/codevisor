import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptProjectionPublicationStateTests {
  private static let sessionID = UUID()

  private func request(
    controllerRevision: UInt64 = 1,
    modelRevision: UInt64 = 1,
    bottomSpacerHeight: CGFloat = 80
  ) -> TranscriptProjectionRequest {
    TranscriptProjectionRequest(
      key: TranscriptProjectionKey(
        sessionID: Self.sessionID, controllerRevision: controllerRevision, modelRevision: modelRevision),
      options: .init(includesConnectingRow: false, bottomSpacerHeight: bottomSpacerHeight)
    )
  }

  @Test func historyRequestInvalidatesPublishedLoadingProjectionImmediately() {
    let loading = request(controllerRevision: 1)
    let history = request(controllerRevision: 2)
    var publication = TranscriptProjectionPublicationState()

    #expect(publication.isPending(currentRequest: loading))

    publication.publish(loading)
    #expect(!publication.isPending(currentRequest: loading))

    #expect(publication.isPending(currentRequest: history))

    publication.publish(history)
    #expect(!publication.isPending(currentRequest: history))
  }

  @Test func newerLiveEventsDoNotHoldBackAPublishedProjection() {
    var publication = TranscriptProjectionPublicationState()

    publication.publish(request(modelRevision: 4))

    #expect(!publication.isPending(currentRequest: request(modelRevision: 9)))
    #expect(publication.isPending(currentRequest: request(modelRevision: 3)))
    #expect(publication.isPending(currentRequest: request(modelRevision: 9, bottomSpacerHeight: 120)))
  }

  @Test func resetMakesAPreviouslyPublishedRequestPendingAgain() {
    let current = request()
    var publication = TranscriptProjectionPublicationState(
      publishedRequest: current
    )

    publication.reset()

    #expect(publication.isPending(currentRequest: current))
  }
}
