import Foundation
import Testing
import ACPKit
import CodevisorClient
@testable import CodevisorCloud

// MARK: - Scripted direct machine

/// The machine end of a direct pipe for tests: answers hello with the direct
/// welcome (no machine list — the wire shape DirectChannelHost sends), pongs
/// pings, and runs relay envelopes through a `ScriptedRelayMachine`'s
/// responder crypto.
final class ScriptedDirectMachine: @unchecked Sendable {
    let machine: ScriptedRelayMachine
    let socket = FakeWebSocketConnection()
    private let lock = NSLock()
    private var helloPublicKey: String?
    var acceptsHello = true
    var respondsToPing = true
    private(set) var pingCount = 0
    private var creditEnvelopes: [(channelId: String, seq: UInt64, bytes: Int)] = []

    private struct RelayHeader: Codable {
        var machineId: String
        var frame: CloudRelayFrame
    }

    init(machine: ScriptedRelayMachine = ScriptedRelayMachine()) {
        self.machine = machine
        socket.onSend = { [weak self] message in
            self?.handle(message)
        }
    }

    var appPublicKey: String? {
        lock.withLock { helloPublicKey }
    }

    var credits: [(channelId: String, seq: UInt64, bytes: Int)] {
        lock.withLock { creditEnvelopes }
    }

    var pings: Int {
        lock.withLock { pingCount }
    }

    func sendToApp(frame: CloudRelayFrame, payload: Data = Data()) {
        let header = try! JSONEncoder().encode(
            RelayHeader(machineId: machine.deviceId, frame: frame))
        socket.push(.data(CloudRelayWire.encode([CloudRelayEnvelope(header: header, payload: payload)])))
    }

    private func handle(_ message: ServerWebSocketMessage) {
        switch message {
        case let .data(binary):
            guard let envelopes = try? CloudRelayWire.decode(binary) else { return }
            for wire in envelopes {
                guard let header = try? JSONDecoder().decode(RelayHeader.self, from: wire.header),
                    header.machineId == machine.deviceId,
                    let appKey = appPublicKey
                else { continue }
                if case let .credit(channelId, seq, bytes) = header.frame {
                    lock.withLock { creditEnvelopes.append((channelId, seq, bytes)) }
                }
                _ = try? machine.receive(header.frame, payload: wire.payload, appPublicKey: appKey)
            }
        case let .string(text):
            let data = Data(text.utf8)
            struct Probe: Decodable {
                var t: String
            }
            guard let probe = try? JSONDecoder().decode(Probe.self, from: data) else { return }
            switch probe.t {
            case "hello":
                struct Hello: Decodable {
                    struct Device: Decodable {
                        var publicKey: String
                    }

                    var device: Device
                }
                guard acceptsHello, let hello = try? JSONDecoder().decode(Hello.self, from: data)
                else { return }
                lock.withLock { helloPublicKey = hello.device.publicKey }
                socket.pushJSON(#"{"t":"welcome","protocol":2,"connectionId":"direct-1"}"#)
            case "ping":
                lock.withLock { pingCount += 1 }
                if respondsToPing {
                    socket.pushJSON(#"{"t":"pong"}"#)
                }
            default:
                break
            }
        }
    }
}

func makeDirectConnection(
    to scripted: ScriptedDirectMachine,
    readyTimeout: Duration = .seconds(2),
    heartbeatInterval: Duration = .seconds(60),
    heartbeatTimeout: Duration = .seconds(5),
    onDown: (@Sendable () -> Void)? = nil
) -> CloudDirectConnection {
    CloudDirectConnection(
        directURL: URL(string: "ws://192.168.1.20:4931/v1/direct")!,
        machineDeviceId: scripted.machine.deviceId,
        machinePublicKey: scripted.machine.publicKey,
        credentialStore: InMemoryCloudCredentialStore(),
        webSocketTransport: FakeWebSocketTransport { _ in scripted.socket },
        readyTimeout: readyTimeout,
        heartbeatInterval: heartbeatInterval,
        heartbeatTimeout: heartbeatTimeout,
        onDown: onDown
    )
}

// MARK: - Tests

@Suite("CloudDirectConnection")
struct CloudDirectConnectionTests {
    @Test("Opens sealed channels straight over the direct socket, both directions")
    func channelRoundTrip() async throws {
        let scripted = ScriptedDirectMachine()
        let connection = makeDirectConnection(to: scripted)
        let recorder = Recorder()

        let channel = try await connection.openChannel(
            channelType: "http",
            params: .object(["path": .string("/v1/info")]),
            compressed: true,
            onMessage: { recorder.record($0) },
            onClosed: { recorder.recordClose($0) }
        )

        // The scripted machine completed the responder key agreement from
        // the open envelope — the sealed round trip the prober relies on.
        try await channel.sendJSON(["kind": "end"])
        #expect(
            await waitUntil {
                scripted.machine.channel(channel.id)?.messages.isEmpty == false
            })
        let received = try #require(scripted.machine.channel(channel.id)?.messages.first)
        #expect(String(decoding: received, as: UTF8.self).contains("end"))

        let sealed = try scripted.machine.sealData(
            channelId: channel.id, payload: Data("pong-body".utf8))
        scripted.sendToApp(frame: sealed.frame, payload: sealed.payload)
        #expect(await waitUntil { !recorder.messages.isEmpty })
        #expect(recorder.messages.first == Data("pong-body".utf8))
        // Structured channels carry no credit traffic (no auto-replenish).
        #expect(scripted.credits.isEmpty)
        #expect(recorder.closes.isEmpty)
    }

    @Test("A silent listener times out instead of hanging the opener")
    func helloTimeout() async throws {
        let scripted = ScriptedDirectMachine()
        scripted.acceptsHello = false
        let connection = makeDirectConnection(to: scripted, readyTimeout: .milliseconds(150))

        await #expect(throws: CloudHubConnectionError.timedOut) {
            try await connection.waitUntilReady()
        }
    }

    @Test("Socket death fails channels, fires onDown once, and stays dead")
    func socketDeath() async throws {
        let scripted = ScriptedDirectMachine()
        let downs = Recorder()
        let connection = makeDirectConnection(to: scripted) { downs.record(Data()) }
        let recorder = Recorder()

        _ = try await connection.openChannel(
            channelType: "ws",
            params: nil,
            onMessage: { recorder.record($0) },
            onClosed: { recorder.recordClose($0) }
        )
        scripted.socket.disconnect()

        #expect(await waitUntil { recorder.closes.count == 1 })
        #expect(recorder.closes == [nil])
        #expect(await waitUntil { downs.messages.count == 1 })
        // The pipe is single-shot: no reconnect loop, no second onDown.
        await #expect(throws: CloudHubConnectionError.disconnected) {
            _ = try await connection.openChannel(
                channelType: "ws", params: nil, onMessage: { _ in }, onClosed: { _ in })
        }
        #expect(downs.messages.count == 1)
    }

    @Test("A missed pong deadline tears the pipe down")
    func heartbeatDeadline() async throws {
        let scripted = ScriptedDirectMachine()
        scripted.respondsToPing = false
        let downs = Recorder()
        let connection = makeDirectConnection(
            to: scripted,
            heartbeatInterval: .milliseconds(50),
            heartbeatTimeout: .milliseconds(80)
        ) { downs.record(Data()) }

        try await connection.waitUntilReady()
        #expect(await waitUntil { downs.messages.count == 1 })
        #expect(scripted.pings >= 1)
    }

    @Test("Shutdown is silent: channels fail but onDown never fires")
    func silentShutdown() async throws {
        let scripted = ScriptedDirectMachine()
        let downs = Recorder()
        let connection = makeDirectConnection(to: scripted) { downs.record(Data()) }
        let recorder = Recorder()

        _ = try await connection.openChannel(
            channelType: "ws",
            params: nil,
            onMessage: { _ in },
            onClosed: { recorder.recordClose($0) }
        )
        await connection.shutdown()

        #expect(await waitUntil { recorder.closes.count == 1 })
        try? await Task.sleep(for: .milliseconds(50))
        #expect(downs.messages.isEmpty)
    }
}

@Suite("SwitchingChannelTransport")
struct SwitchingChannelTransportTests {
    @Test("Each open asks the provider which pipe is best right now")
    func switchesPerOpen() async throws {
        let first = ScriptedDirectMachine()
        let second = ScriptedDirectMachine(
            machine: ScriptedRelayMachine(deviceId: first.machine.deviceId))
        let firstConnection = makeDirectConnection(to: first)
        let secondConnection = makeDirectConnection(to: second)
        let useSecond = Recorder()
        let transport = SwitchingChannelTransport(machineDeviceId: first.machine.deviceId) {
            useSecond.messages.isEmpty
                ? CloudDirectTransport(connection: firstConnection)
                : CloudDirectTransport(connection: secondConnection)
        }
        #expect(transport.machineDeviceId == first.machine.deviceId)

        let overFirst = try await transport.openChannel(
            channelType: "http", params: nil, compressed: false,
            onMessage: { _ in }, onClosed: { _ in })
        #expect(await waitUntil { first.machine.channel(overFirst.id) != nil })
        #expect(second.machine.channel(overFirst.id) == nil)

        useSecond.record(Data())  // the first pipe "went down"
        let overSecond = try await transport.openChannel(
            channelType: "http", params: nil, compressed: false,
            onMessage: { _ in }, onClosed: { _ in })
        #expect(await waitUntil { second.machine.channel(overSecond.id) != nil })
        #expect(first.machine.channel(overSecond.id) == nil)
    }
}
