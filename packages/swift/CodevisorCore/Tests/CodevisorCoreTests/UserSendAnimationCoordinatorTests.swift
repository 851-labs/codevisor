import Foundation
import Testing
@testable import CodevisorCore

@Suite("UserSendAnimationCoordinator")
struct UserSendAnimationCoordinatorTests {
    @Test("A request can be claimed exactly once across view rebuilds")
    func claimIsExactlyOnce() {
        var coordinator = UserSendAnimationCoordinator()
        let request = coordinator.issue(for: UUID(), destination: .optimistic)

        let firstClaim = coordinator.claim(request)
        #expect(firstClaim)
        // A rebuilt transcript receives the same controller-owned request.
        let remountClaim = coordinator.claim(request)
        #expect(!remountClaim)
    }

    @Test("A request remains claimable until its target row mounts")
    func delayedMountCanClaim() {
        var coordinator = UserSendAnimationCoordinator()
        let request = coordinator.issue(for: UUID(), destination: .activeTurn)

        // There is deliberately no wall-clock expiry between issue and claim.
        let delayedClaim = coordinator.claim(request)
        #expect(delayedClaim)
    }

    @Test("A newer send supersedes an unclaimed request")
    func newerRequestSupersedesOlderRequest() {
        var coordinator = UserSendAnimationCoordinator()
        let older = coordinator.issue(for: UUID(), destination: .optimistic)
        let newer = coordinator.issue(for: UUID(), destination: .activeTurn)

        let staleClaim = coordinator.claim(older)
        let currentClaim = coordinator.claim(newer)
        #expect(!staleClaim)
        #expect(currentClaim)
    }

    @Test("A cancelled failed send cannot animate later")
    func cancelledRequestCannotBeClaimed() {
        var coordinator = UserSendAnimationCoordinator()
        let request = coordinator.issue(for: UUID(), destination: .activeTurn)

        coordinator.cancel(request)

        let cancelledClaim = coordinator.claim(request)
        #expect(!cancelledClaim)
    }

    @Test("A request retains the geometry destination used at issue time")
    func retainsDestination() {
        var coordinator = UserSendAnimationCoordinator()
        let request = coordinator.issue(for: UUID(), destination: .activeTurn)

        #expect(request.destination == .activeTurn)
    }
}
