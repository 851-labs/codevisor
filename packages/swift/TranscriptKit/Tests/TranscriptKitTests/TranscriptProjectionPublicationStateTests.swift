import Testing
@testable import TranscriptKit

struct TranscriptProjectionPublicationStateTests {
    private struct Request: Equatable, Sendable {
        let revision: Int
    }

    @Test func historyRequestInvalidatesPublishedLoadingProjectionImmediately() {
        let loading = Request(revision: 1)
        let history = Request(revision: 2)
        var publication = TranscriptProjectionPublicationState<Request>()

        #expect(publication.isPending(currentRequest: loading))

        publication.publish(loading)
        #expect(!publication.isPending(currentRequest: loading))

        // The controller has advanced to hydrated history, but the async row
        // projection has not committed yet. The obsolete empty rows must not
        // be eligible for the transcript's one-way initial reveal.
        #expect(publication.isPending(currentRequest: history))

        publication.publish(history)
        #expect(!publication.isPending(currentRequest: history))
    }

    @Test func resetMakesAPreviouslyPublishedRequestPendingAgain() {
        let request = Request(revision: 1)
        var publication = TranscriptProjectionPublicationState(
            publishedRequest: request
        )

        publication.reset()

        #expect(publication.isPending(currentRequest: request))
    }

    @Test func obsoleteEmptyProjectionCannotOpenInitialPresentationGate() {
        let loading = Request(revision: 1)
        let history = Request(revision: 2)
        var publication = TranscriptProjectionPublicationState(
            publishedRequest: loading
        )
        var gate = TranscriptInitialPresentationGate()

        let obsoleteReveal = gate.resolve(
            isHydrating: publication.isPending(currentRequest: history),
            requiredKeys: [],
            resolvedKeys: []
        )
        #expect(!obsoleteReveal)
        #expect(!gate.isReady)

        publication.publish(history)
        let aggregateReveal = gate.resolve(
            isHydrating: publication.isPending(currentRequest: history),
            isActiveProjectionPending: true,
            requiredKeys: ["active-aggregate"],
            resolvedKeys: ["active-aggregate"]
        )
        #expect(!aggregateReveal)
        #expect(!gate.isReady)

        let blockReveal = gate.resolve(
            isHydrating: false,
            isActiveProjectionPending: false,
            requiredKeys: ["markdown-0", "markdown-1"],
            resolvedKeys: ["markdown-0", "markdown-1"]
        )
        #expect(blockReveal)
        #expect(gate.isReady)
    }
}
