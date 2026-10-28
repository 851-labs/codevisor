import ACPKit
import Foundation
import Testing
import TranscriptKit

@testable import CodevisorClient

struct ServerSessionAutoResumeTests {
  private let resetsAt = Date(timeIntervalSince1970: 1_792_533_600)

  @Test("A transcript page carries the chat's pending auto-resume and its reset time")
  func transcriptPage() throws {
    let scheduled = try decodePage(#", "autoResume": { "resumesAt": "2026-10-20T22:00:00.000Z" }"#)
    let unknownTime = try decodePage(#", "autoResume": {}"#)
    let resuming = try decodePage(#", "autoResume": { "state": "resuming" }"#)
    let none = try decodePage("")

    #expect(scheduled.autoResume?.sessionAutoResume == SessionAutoResume(resumesAt: resetsAt))
    #expect(unknownTime.autoResume?.sessionAutoResume == SessionAutoResume())
    #expect(resuming.autoResume?.sessionAutoResume == SessionAutoResume(state: .resuming))
    #expect(none.autoResume == nil)
  }

  @Test("Live updates schedule the auto-resume, show it resuming or failed, or clear it")
  func liveUpdates() {
    let scheduled = decode(["state": .string("scheduled"), "resumesAt": .string("2026-10-20T22:00:00Z")])
    let unknownTime = decode(["state": .string("scheduled")])
    let resuming = decode(["state": .string("resuming")])
    let failed = decode(["state": .string("failed")])
    let cleared = decode(["state": .string("cleared")])

    #expect(scheduled == [.autoResume(SessionAutoResume(resumesAt: resetsAt))])
    #expect(unknownTime == [.autoResume(SessionAutoResume())])
    #expect(resuming == [.autoResume(SessionAutoResume(state: .resuming))])
    #expect(failed == [.autoResume(SessionAutoResume(state: .failed))])
    #expect(cleared == [.autoResume(nil)])
  }

  private func decodePage(_ autoResume: String) throws -> ServerTranscriptPage {
    let json = """
      {
        "items": [], "hasNewer": false, "hasMore": false, "eventCursor": 4,
        "stateUpdates": [], "setupActivities": []\(autoResume)
      }
      """
    return try JSONDecoder().decode(ServerTranscriptPage.self, from: Data(json.utf8))
  }

  private func decode(_ payload: [String: JSONValue]) -> [ServerSessionStreamEvent] {
    ServerSessionEventDecoder.decode(
      from: ServerEventEnvelope(
        id: 1,
        serverId: "local",
        kind: "session.autoResume.updated",
        subjectId: "s1",
        createdAt: "2026-10-20T21:00:00.000Z",
        payload: .object(payload)
      ))
  }
}
