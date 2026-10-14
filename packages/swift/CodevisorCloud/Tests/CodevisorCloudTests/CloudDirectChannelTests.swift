import CodevisorTestSupport
import Foundation
import Testing
import ACPKit
import CodevisorClient
@testable import CodevisorCloud

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

    #expect(await waitUntil { machine.channel(channel.id)?.openPayload != nil })
    let openPayload = try #require(machine.channel(channel.id)?.openPayload)
    let decoded = try JSONDecoder().decode(JSONValue.self, from: openPayload)
    #expect(decoded["channelType"] == .string("test"))
    #expect(decoded["params"]?["hello"] == .string("world"))

    try await channel.send(plaintext: JSONEncoder().encode(["kind": "first"]))
    try await channel.send(plaintext: JSONEncoder().encode(["kind": "second"]))
    #expect(await waitUntil { machine.channel(channel.id)?.messages.count == 2 })
    let sentSeqs = scripted.frames.filter {
      if case .data = $0 { return true }
      return false
    }.map(\.seq)
    #expect(sentSeqs == [1, 2])

    scripted.sendToApp(sealed: try machine.sealData(channelId: channel.id, payload: Data("reply-1".utf8)))
    scripted.sendToApp(sealed: try machine.sealData(channelId: channel.id, payload: Data("reply-2".utf8)))
    #expect(await waitUntil { recorder.messages.count == 2 })
    #expect(recorder.messages.map { String(decoding: $0, as: UTF8.self) } == ["reply-1", "reply-2"])

    #expect(scripted.credits.isEmpty)

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

    try await channel.send(plaintext: JSONEncoder().encode(["kind": "request"]))
    #expect(await waitUntil { machine.channel(channel.id)?.messages.count == 1 })
    let request = try #require(machine.channel(channel.id)?.messages.first)
    #expect(try JSONDecoder().decode([String: String].self, from: request) == ["kind": "request"])

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
    try await channel.grantCredit(bytes: 16)
    scripted.sendToApp(sealed: try machine.sealData(channelId: channel.id, payload: Data([1])))

    await closed.wait()
    #expect(recorder.closes == [.protocolError])
    #expect(recorder.messages.isEmpty)
    await connection.shutdown()
  }
}
