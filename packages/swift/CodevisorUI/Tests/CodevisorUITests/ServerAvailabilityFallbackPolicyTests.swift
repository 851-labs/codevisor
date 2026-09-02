import CodevisorClient
import Testing
@testable import CodevisorUI

@Suite("Server availability local fallback")
struct ServerAvailabilityFallbackPolicyTests {
    @Test("An unreachable remote composer machine offers this Mac")
    func remoteOpenEndedWaitsOfferLocal() {
        for availability in [
            ServerAvailability.waiting(.connecting),
            .waiting(.starting),
            .failed("Could not reach tuftlord"),
        ] {
            #expect(
                ServerAvailabilityFallbackPolicy.offersLocalMachine(
                    isLocal: false,
                    availability: availability,
                    hasLocalMachine: true
                ),
                "\(availability) should offer the local machine"
            )
        }
    }

    @Test("The local machine never offers itself")
    func localMachineHasNoFallback() {
        #expect(
            !ServerAvailabilityFallbackPolicy.offersLocalMachine(
                isLocal: true,
                availability: .waiting(.connecting),
                hasLocalMachine: true
            ))
        #expect(
            !ServerAvailabilityFallbackPolicy.offersLocalMachine(
                isLocal: true,
                availability: .failed("down"),
                hasLocalMachine: true
            ))
    }

    @Test("No local machine in the fleet means nothing to fall back to")
    func requiresALocalMachine() {
        #expect(
            !ServerAvailabilityFallbackPolicy.offersLocalMachine(
                isLocal: false,
                availability: .failed("down"),
                hasLocalMachine: false
            ))
    }

    @Test("Finite transitions keep the user waiting")
    func finiteTransitionsDoNotOfferLocal() {
        for availability in [ServerAvailability.waiting(.updating), .waiting(.restarting), .ready] {
            #expect(
                !ServerAvailabilityFallbackPolicy.offersLocalMachine(
                    isLocal: false,
                    availability: availability,
                    hasLocalMachine: true
                ),
                "\(availability) should not offer the local machine"
            )
        }
        #expect(
            !ServerAvailabilityFallbackPolicy.offersLocalMachine(
                isLocal: false,
                availability: .waiting(.connecting),
                hasLocalMachine: true,
                appUpdateInProgress: true
            ))
        #expect(
            !ServerAvailabilityFallbackPolicy.offersLocalMachine(
                isLocal: false,
                availability: .waiting(.connecting),
                hasLocalMachine: true,
                migrationInProgress: true
            ))
    }
}
