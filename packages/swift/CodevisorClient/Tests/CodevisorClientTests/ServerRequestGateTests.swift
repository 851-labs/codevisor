import Foundation
import Testing
import CodevisorProtocol

@testable import CodevisorClient

@Suite("Server request gate")
struct ServerRequestGateTests {
    @Test("Requests wait until the machine is ready")
    func waitsForReady() async throws {
        let gate = ServerRequestGate()
        let completion = CompletionFlag()
        gate.beginWaiting(for: "local")

        let request = Task {
            try await gate.waitUntilReady(for: "local")
            await completion.finish()
        }
        try await Task.sleep(for: .milliseconds(20))
        #expect(await completion.value == false)

        gate.markReady(for: "local")
        try await request.value
        #expect(await completion.value == true)
    }

    @Test("A failed startup releases requests with the startup error")
    func failureReleasesWaiters() async {
        let gate = ServerRequestGate()
        gate.beginWaiting(for: "remote")

        let request = Task {
            try await gate.waitUntilReady(for: "remote")
        }
        await Task.yield()
        gate.markFailed(for: "remote", message: "Server did not start")

        await #expect(throws: ServerRequestGateError.self) {
            try await request.value
        }
    }

    @Test("Machines without an active lifecycle wait pass through")
    func readyByDefault() async throws {
        let gate = ServerRequestGate()
        try await gate.waitUntilReady(for: "unmanaged")
    }

    @Test("A readiness wait times out instead of hanging forever")
    func timeoutReleasesWaiter() async {
        let gate = ServerRequestGate()
        gate.beginWaiting(for: "stuck")

        await #expect(throws: ServerRequestGateError.self) {
            try await gate.waitUntilReady(for: "stuck", timeout: .milliseconds(20))
        }
    }
}

private actor CompletionFlag {
    private(set) var value = false

    func finish() {
        value = true
    }
}
