import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptAutoResumeStampTests {
  private let pending = SessionAutoResume(resumesAt: Date(timeIntervalSince1970: 1_792_533_600))

  @Test func stampsThePendingResumeOnlyOnTheLatestUsageLimitedTurn() {
    let earlier = assistant(stopKind: "usageLimit")
    let latest = assistant(stopKind: "usageLimit")
    let conversation = [earlier, user(), latest]

    let stamped = TranscriptAutoResumeStamp.stamping(pending, onto: conversation)

    #expect(autoResume(of: stamped[0]) == nil)
    #expect(autoResume(of: stamped[2]) == pending)
  }

  @Test func stampsTheLiveTurnWhenItStoppedAtTheUsageLimit() {
    let limited = assistant(stopKind: "usageLimit")
    let answered = assistant(stopKind: nil)

    #expect(autoResume(of: TranscriptAutoResumeStamp.stamping(pending, onto: limited)) == pending)
    #expect(TranscriptAutoResumeStamp.stamping(pending, onto: answered) == answered)
    #expect(TranscriptAutoResumeStamp.stamping(nil, onto: limited) == limited)
    #expect(TranscriptAutoResumeStamp.stamping(pending, onto: nil as ConversationItem?) == nil)
  }

  @Test func leavesTheTranscriptAloneWithoutAPendingResumeOrAUsageLimitedLatestTurn() {
    let limited = [assistant(stopKind: "usageLimit")]
    let answered = [assistant(stopKind: "usageLimit"), user(), assistant(stopKind: nil)]
    let empty = [user()]

    #expect(TranscriptAutoResumeStamp.stamping(nil, onto: limited) == limited)
    #expect(TranscriptAutoResumeStamp.stamping(pending, onto: answered) == answered)
    #expect(TranscriptAutoResumeStamp.stamping(pending, onto: empty) == empty)
  }

  private func assistant(stopKind: String?) -> ConversationItem {
    .assistant(
      AssistantMessage(
        id: UUID(),
        turn: AssistantTurn(stopDetail: "You've hit your session limit", stopKind: stopKind)
      ))
  }

  private func user() -> ConversationItem {
    .user(UserMessage(id: UUID(), text: "Keep going"))
  }

  private func autoResume(of item: ConversationItem?) -> SessionAutoResume? {
    guard case let .assistant(message)? = item else { return nil }
    return message.turn.autoResume
  }
}
