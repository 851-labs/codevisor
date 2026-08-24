import Foundation
import Testing
import ACPKit
import CodevisorClient
@testable import CodevisorCloud

/// Phase 6 behavior: http/ws channels run under negotiated credit-based flow
/// control in both directions, and streamed responses are consumer-paced.
@Suite("CloudRelay flow control")
struct CloudRelayFlowControlTests {
    @Test("Uploads gate on the machine's window: no grant, no frames")
    func uploadGatesOnCredit() async throws {
        let scriptedMachine = ScriptedHttpMachine()
        scriptedMachine.grantsUploadWindow = false
        scriptedMachine.respond = { _ in
            ScriptedHttpMachine.ScriptedResponse(status: 200, headers: [:], bodyChunks: [])
        }
        let (endpoint, hub) = makeRelayEndpoint(
            scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
        let transport = CloudRelayRequestTransport(endpoint: endpoint, timeout: .milliseconds(300))
        var request = URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/upload")!)
        request.httpMethod = "POST"
        request.httpBody = Data("held until granted".utf8)

        await #expect(throws: CloudRelayTransportError.timedOut) {
            _ = try await transport.data(for: request)
        }
        // Not even the first chunk frame made it out.
        #expect(scriptedMachine.completedRequests.isEmpty)
        await hub.shutdown()
    }

    @Test("A late grant releases a waiting upload")
    func lateGrantReleasesUpload() async throws {
        let scriptedMachine = ScriptedHttpMachine()
        scriptedMachine.grantsUploadWindow = false
        scriptedMachine.respond = { request in
            ScriptedHttpMachine.ScriptedResponse(
                status: 200, headers: [:], bodyChunks: [request.body])
        }
        let (endpoint, hub) = makeRelayEndpoint(
            scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
        let transport = CloudRelayRequestTransport(endpoint: endpoint)
        var request = URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/upload")!)
        request.httpMethod = "POST"
        request.httpBody = Data("held until granted".utf8)

        let pending = Task { try await transport.data(for: request) }
        #expect(await waitUntil { !scriptedMachine.openChannelIds.isEmpty })
        let channelId = scriptedMachine.openChannelIds[0]
        scriptedMachine.grantUploadWindow(channelId: channelId)

        let (data, response) = try await pending.value
        #expect(response.statusCode == 200)
        #expect(data == Data("held until granted".utf8))
        await hub.shutdown()
    }

    @Test("Streamed responses replenish the machine's window per consumed chunk")
    func streamingReplenishesWindow() async throws {
        let first = Data(repeating: 0x61, count: 2_048)
        let second = Data(repeating: 0x62, count: 2_048)
        let scriptedMachine = ScriptedHttpMachine()
        scriptedMachine.respond = { _ in
            ScriptedHttpMachine.ScriptedResponse(
                status: 200, headers: [:], bodyChunks: [first, second], sendsClose: false)
        }
        let (endpoint, hub) = makeRelayEndpoint(
            scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
        let transport = CloudRelayRequestTransport(endpoint: endpoint)
        let request = URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/big")!)

        let (response, body) = try await transport.stream(for: request)
        #expect(response.statusCode == 200)
        var chunks: [Data] = []
        for try await chunk in body {
            chunks.append(chunk)
        }
        #expect(chunks == [first, second])

        // The app granted its initial window plus one replenish per consumed
        // frame (head, two chunks, end).
        #expect(await waitUntil { scriptedMachine.creditGrants.count >= 5 })
        #expect(scriptedMachine.creditGrants[0] == 1024 * 1024)

        // The open advertised both negotiations to the machine.
        struct OpenProbe: Decodable {
            var compress: Bool?
            var flowControl: Bool?
        }
        let openPayload = try #require(
            scriptedMachine.machine.channel(scriptedMachine.openChannelIds[0])?.openPayload)
        let probe = try JSONDecoder().decode(OpenProbe.self, from: openPayload)
        #expect(probe.compress == true)
        #expect(probe.flowControl == true)
        await hub.shutdown()
    }

    @Test("ws windows replenish only as messages are consumed")
    func wsConsumerPacedCredit() async throws {
        let scriptedMachine = ScriptedWsMachine()
        let (endpoint, hub) = makeRelayEndpoint(
            scripted: scriptedMachine.scripted, machine: scriptedMachine.machine)
        let connection = CloudRelayWebSocketTransport(endpoint: endpoint).connect(
            URLRequest(url: URL(string: "https://cloud-relay.invalid/v1/events/socket")!),
            maximumMessageSize: 1024 * 1024
        )
        try await connection.send(.string("subscribe"))
        #expect(await waitUntil { scriptedMachine.openChannelId != nil })

        let credits: @Sendable () -> Int = {
            scriptedMachine.scripted.relayEnvelopes.filter {
                if case .credit = $0.frame { return true }
                return false
            }.count
        }
        // Settled: the app's initial window grant only.
        #expect(await waitUntil { credits() == 1 })

        scriptedMachine.push(#"{"kind":"text","data":"one"}"#)
        scriptedMachine.push(#"{"kind":"text","data":"two"}"#)
        #expect(relayMessageText(try await connection.receive()) == "one")
        #expect(await waitUntil { credits() == 2 })
        // The second message is delivered but unconsumed — no grant for it.
        try? await Task.sleep(for: .milliseconds(50))
        #expect(credits() == 2)
        #expect(relayMessageText(try await connection.receive()) == "two")
        #expect(await waitUntil { credits() == 3 })

        connection.cancel(with: .normalClosure, reason: nil)
        await hub.shutdown()
    }
}
