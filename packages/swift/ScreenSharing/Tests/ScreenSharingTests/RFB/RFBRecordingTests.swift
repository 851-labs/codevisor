import CodevisorTestSupport
import Foundation
import Testing
import ScreenSharingTesting
@testable import ScreenSharing

/// Real-server recordings replayed with no server (851-2326): each fixture in
/// `Fixtures/` must reproduce, byte for byte, the outcome it was recorded
/// with. Record new ones with `screen-sharing-rig vnc-record` (see
/// `Fixtures/README.md`).
struct RFBRecordingTests {
  static let fixtures: [URL] = {
    let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
    let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
    return names.filter { $0.hasSuffix(".json") }.sorted().map { directory.appendingPathComponent($0) }
  }()

  @Test func thereAreFixtures() {
    #expect(!Self.fixtures.isEmpty)
  }

  @Test(arguments: RFBRecordingTests.fixtures)
  func aRecordingReplaysToItsRecordedOutcome(_ url: URL) async throws {
    let recording = try RFBRecording.load(url)
    let expected = try #require(recording.expected, "\(url.lastPathComponent) has no expected outcome")
    let replayed = RFBRecording.comparable(try await recording.replay(), lossy: expected.framebuffer == "lossy")
    #expect(replayed == expected, "\(url.lastPathComponent)")
  }

  /// The TigerVNC fixture pins what that server actually sends when a client
  /// with every extension connects and moves the pointer.
  @Test func theTigerVNCOpeningIsWhatTheExtensionsExpect() async throws {
    let url = try #require(Self.fixtures.first { $0.lastPathComponent == "tigervnc-1.15-opening.json" })
    let events = try #require(try RFBRecording.load(url).expected?.events)
    #expect(events.first == "continuousUpdates(true)")
    #expect(events.contains { $0.hasPrefix("clipboard caps formats 1") })
    #expect(events.contains("cursor 0x0 hotspot 0,0"), "hidden until this client moves the pointer")
    #expect(events.contains("desktop 1024x768 server ok screens 1"))
    #expect(events.contains("cursor 10x16 hotspot 1,1"), "left_ptr after the move")
  }

  /// Recording the reference server and replaying gives the framebuffer the live client ended with.
  @Test func aRecordingOfTheReferenceServerReplaysToTheLiveFramebuffer() async throws {
    var configuration = RFBLoopbackServer.Configuration()
    configuration.encoding = .zrle
    configuration.cursor = .referenceArrow
    let server = try await RFBLoopbackServer(configuration: configuration)
    defer { server.stop() }
    let transport = RFBRecordingTransport(try await RFBNetworkTransport.connect(host: "127.0.0.1", port: server.port))
    let client = try RFBClient(transport: transport)
    let outcome = try await client.connect(password: "secret")
    transport.start()
    let (updates, continuation) = AsyncStream<Void>.makeStream()
    let run = Task { try await client.run(onUpdate: { _, _ in continuation.yield() }, onEvent: { _ in }) }
    defer {
      run.cancel()
      client.close()
    }
    var iterator = updates.makeAsyncIterator()
    _ = await iterator.next()
    var scene = RFBLoopbackScene(kind: .scroll, seed: 9)
    for _ in 0..<5 {
      #expect(try server.play(&scene))
      _ = await iterator.next()
    }
    transport.stop()
    let recording = RFBRecording(
      source: "reference", width: outcome.parameters.width, height: outcome.parameters.height,
      server: transport.recorded)
    let replayed = try await recording.replay()
    #expect(replayed.updates == 6)
    #expect(replayed.framebuffer == RFBRecording.digest(client.framebuffer))
    #expect(replayed.events.contains("cursor 11x16 hotspot 0,0"))
    // JSON round trip of the fixture format.
    let file = FileManager.default.temporaryDirectory.appendingPathComponent("\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: file) }
    try recording.write(to: file)
    #expect(try RFBRecording.load(file) == recording)
  }
}
