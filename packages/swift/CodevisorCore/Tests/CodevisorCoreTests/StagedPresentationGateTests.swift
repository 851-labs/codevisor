import Testing
@testable import CodevisorCore

struct StagedPresentationGateTests {
    @Test func destinationCommitsOnlyAfterItsCurrentRequest() {
        var gate = StagedPresentationGate<String>()

        let firstGeneration = gate.request("first")
        #expect(gate.presentedRoute == nil)
        let didCommit = gate.commit("first", generation: firstGeneration)
        #expect(didCommit)
        #expect(gate.presentedRoute == "first")
    }

    @Test func rapidNavigationRejectsAStaleCommit() {
        var gate = StagedPresentationGate<String>()

        let staleGeneration = gate.request("first")
        let currentGeneration = gate.request("second")

        let didCommitStaleRoute = gate.commit("first", generation: staleGeneration)
        #expect(!didCommitStaleRoute)
        #expect(gate.presentedRoute == nil)
        let didCommitCurrentRoute = gate.commit("second", generation: currentGeneration)
        #expect(didCommitCurrentRoute)
        #expect(gate.presentedRoute == "second")
    }

    @Test func outgoingRouteRemainsPresentedUntilIncomingIsReady() {
        var gate = StagedPresentationGate<String>()
        let initialGeneration = gate.request("old")
        _ = gate.commit("old", generation: initialGeneration)

        let incomingGeneration = gate.request("new")

        #expect(gate.requestedRoute == "new")
        #expect(gate.presentedRoute == "old")
        let didCommit = gate.commit("new", generation: incomingGeneration)
        #expect(didCommit)
        #expect(gate.presentedRoute == "new")
    }

    @Test func anOptionalNilRouteIsStillACommittedRoute() {
        var gate = StagedPresentationGate<String?>()

        let generation = gate.request(nil)
        let didCommit = gate.commit(nil, generation: generation)

        #expect(didCommit)
        #expect(gate.presentedRoute != nil)
        #expect(gate.presentedRoute == .some(nil))
    }
}
