import Foundation
import Testing
import ScreenSharingTesting

struct RFBRecordingTests {
  static let fixtures: [URL] = {
    guard let directory = Bundle.module.url(forResource: "Fixtures", withExtension: nil) else { return [] }
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

  @Test func theTigerVNCOpeningIsWhatTheExtensionsExpect() async throws {
    let url = try #require(Self.fixtures.first { $0.lastPathComponent == "tigervnc-1.15-opening.json" })
    let events = try #require(try RFBRecording.load(url).expected?.events)
    #expect(events.first == "continuousUpdates(true)")
    #expect(events.contains { $0.hasPrefix("clipboard caps formats 1") })
    #expect(events.contains("cursor 0x0 hotspot 0,0"), "hidden until this client moves the pointer")
    #expect(events.contains("desktop 1024x768 server ok screens 1"))
    #expect(events.contains("cursor 10x16 hotspot 1,1"), "left_ptr after the move")
  }
}
