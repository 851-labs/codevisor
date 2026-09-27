import CodevisorTestSupport
import Foundation
import Testing
import ACPKit
import CodevisorClient
@testable import CodevisorCloud

/// The sealed-channel protocol a direct pipe multiplexes: per-direction
/// seqs, close reasons, crypto and framing failures, negotiated compression,
/// and credit enforcement on flow-controlled channels.
@Suite("CloudDirectConnection channels")
struct CloudDirectChannelTests {
  @Test("Opens channels, routes sealed frames, and books seqs per direction")
  func channelMux() async throws {
    let scripted = ScriptedDirectMachine()
    let machine = scripted.machine
    let connection = makeDirectConnection(to: scripted)
    let recorder = Recorder()

    let channel = try await connection.openChannel(
      channelType: "test",
      params: .object(["hello": .string("world")]),
      onMessage: { recorder.record($0) },
      onClosed: { recorder.recordClose($0) }
    )

    // The machine saw the open (seq 0) and decrypted its payload.
    #expect(await waitUntil { machine.channel(channel.id)?.openPayload != nil })
    let openPayload = try #require(machine.channel(channel.id)?.openPayload)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: openPayload)
    #expect(decoded["channelType"] == .string("test"))
    #expect(decoded["params"]?["hello"] == .string("world"))

    // App → machine data frames carry seq 1, 2, ... after the open.
    try await channel.send(plaintext: JSONEncoder().encode(["kind": "first"]))
    try await channel.send(plaintext: JSONEncoder().encode(["kind": "second"]))
    #expect(await waitUntil { machine.channel(channel.id)?.messages.count == 2 })
    let sentSeqs = scripted.frames.filter {
      if case .data = $0 { return true }
      return false
    }.map(\.seq)
    #expect(sentSeqs == [1, 2])

    // Machine → app data frames (seq 0, 1) decrypt and arrive in order.
    scripted.sendToApp(sealed: try machine.sealData(channelId: channel.id, payload: Data("reply-1".utf8)))
    scripted.sendToApp(sealed: try machine.sealData(channelId: channel.id, payload: Data("reply-2".utf8)))
    #expect(await waitUntil { recorder.messages.count == 2 })
    #expect(recorder.messages.map { String(decoding: $0, as: UTF8.self) } == ["reply-1", "reply-2"])

    // Structured channels carry NO credit traffic: machines don't gate
    // sends without negotiated flow control, so auto-replenish would be a
    // pure no-op frame per message.
    #expect(scripted.credits.isEmpty)

    // A machine-initiated close reaches onClosed with its reason.
    scripted.sendToApp(frame: machine.closeFrame(channelId: channel.id, reason: .done))
    #expect(await waitUntil { recorder.closes == [.done] })
    await connection.shutdown()
  }

  @Test("A seq gap on the responder direction kills the channel as protocol-error")
  func seqEnforcement() async throws {
    let scripted = ScriptedDirectMachine()
    let machine = scripted.machine
    let connection = makeDirectConnection(to: scripted)
    let recorder = Recorder()

    let channel = try await connection.openChannel(
      channelType: "test",
      params: nil,
      onMessage: { recorder.record($0) },
      onClosed: { recorder.recordClose($0) }
    )
    #expect(await waitUntil { machine.channel(channel.id) != nil })

    // Frame with seq 4 when 0 is expected → protocol error: the channel
    // closes locally and a close frame goes back to the peer.
    let sealed = try machine.channel(channel.id)!.cipher.seal(
      Data("late".utf8), channelId: channel.id, direction: .responderToOpener, seq: 4
    )
    scripted.sendToApp(frame: .data(channelId: channel.id, seq: 4), payload: sealed)
    #expect(await waitUntil { recorder.closes == [.protocolError] })
    #expect(recorder.messages.isEmpty)
    #expect(
      await waitUntil {
        scripted.frames.contains {
          if case let .close(_, _, reason) = $0 { return reason == .protocolError }
          return false
        }
      })

    // The dead channel rejects further sends.
    await #expect(throws: CloudHubConnectionError.channelClosed) {
      try await channel.send(plaintext: JSONEncoder().encode(["kind": "after-close"]))
    }
    await connection.shutdown()
  }

  @Test("Undecryptable frames kill the channel as crypto-error")
  func cryptoErrorClosesChannel() async throws {
    let scripted = ScriptedDirectMachine()
    let connection = makeDirectConnection(to: scripted)
    let recorder = Recorder()

    let channel = try await connection.openChannel(
      channelType: "test",
      params: nil,
      onMessage: { recorder.record($0) },
      onClosed: { recorder.recordClose($0) }
    )
    scripted.sendToApp(
      frame: .data(channelId: channel.id, seq: 0),
      payload: Data(repeating: 9, count: 32)
    )
    #expect(await waitUntil { recorder.closes == [.cryptoError] })
    await connection.shutdown()
  }

  @Test("Negotiated compression frames payloads and inflates DEFLATE bodies")
  func compressedChannel() async throws {
    let scripted = ScriptedDirectMachine()
    let machine = scripted.machine
    let connection = makeDirectConnection(to: scripted)
    let recorder = Recorder()

    let channel = try await connection.openChannel(
      channelType: "test",
      params: nil,
      compressed: true,
      onMessage: { recorder.record($0) },
      onClosed: { recorder.recordClose($0) }
    )
    #expect(await waitUntil { machine.channel(channel.id)?.compressedFraming == true })

    // App → machine payloads carry the RAW framing byte, which the
    // scripted machine strips before recording.
    try await channel.send(plaintext: JSONEncoder().encode(["kind": "request"]))
    #expect(await waitUntil { machine.channel(channel.id)?.messages.count == 1 })
    let request = try #require(machine.channel(channel.id)?.messages.first)
    #expect(try JSONDecoder().decode([String: String].self, from: request) == ["kind": "request"])

    // Machine → app: RAW and DEFLATE framings both decode to plaintext.
    let big = Data(String(repeating: "terminal output ", count: 256).utf8)
    scripted.sendToApp(sealed: try machine.sealData(channelId: channel.id, payload: Data("plain".utf8)))
    scripted.sendToApp(sealed: try machine.sealDeflated(channelId: channel.id, payload: big))
    #expect(await waitUntil { recorder.messages.count == 2 })
    #expect(recorder.messages[0] == Data("plain".utf8))
    #expect(recorder.messages[1] == big)
    await connection.shutdown()
  }

  @Test("Bad framing on a compressed channel kills it as crypto-error")
  func compressedChannelBadFraming() async throws {
    let scripted = ScriptedDirectMachine()
    let machine = scripted.machine
    let connection = makeDirectConnection(to: scripted)
    let recorder = Recorder()

    let channel = try await connection.openChannel(
      channelType: "test",
      params: nil,
      compressed: true,
      onMessage: { recorder.record($0) },
      onClosed: { recorder.recordClose($0) }
    )
    #expect(await waitUntil { machine.channel(channel.id) != nil })
    // An unknown framing byte is refused like any undecodable payload.
    let bogus = try machine.channel(channel.id)!.cipher.seal(
      Data([7, 1, 2, 3]), channelId: channel.id, direction: .responderToOpener, seq: 0
    )
    scripted.sendToApp(frame: .data(channelId: channel.id, seq: 0), payload: bogus)
    #expect(await waitUntil { recorder.closes == [.cryptoError] })
    await connection.shutdown()
  }

  @Test("A flow-controlled channel rejects data beyond its granted ciphertext budget")
  func flowControlEnforcement() async throws {
    let scripted = ScriptedDirectMachine()
    let machine = scripted.machine
    let connection = makeDirectConnection(to: scripted)
    let recorder = Recorder()
    let closed = TestSignal()

    let channel = try await connection.openFlowControlledChannel(
      channelType: "byte-stream",
      params: .object(["service": .string("codevisor-loopback"), "version": .number(1)]),
      onMessage: { data, _ in recorder.record(data) },
      onCredit: { _ in },
      onClosed: {
        recorder.recordClose($0)
        closed.signal()
      }
    )
    #expect(await waitUntil { machine.channel(channel.id) != nil })
    // An empty raw box costs 16 bytes (the tag). Granting only that much
    // cannot authorize the following one-byte payload (17 bytes).
    try await channel.grantCredit(bytes: 16)
    scripted.sendToApp(sealed: try machine.sealData(channelId: channel.id, payload: Data([1])))

    await closed.wait()
    #expect(recorder.closes == [.protocolError])
    #expect(recorder.messages.isEmpty)
    await connection.shutdown()
  }
}
