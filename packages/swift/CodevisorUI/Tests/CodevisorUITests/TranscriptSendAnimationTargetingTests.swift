import CoreGraphics
import Foundation
import Testing
import TranscriptKit
@testable import CodevisorUI

@Suite("Transcript send animation targeting")
struct TranscriptSendAnimationTargetingTests {
  private typealias Row = TranscriptPresentationRow

  @Test func optimisticSendTargetsAnyUserRow() {
    let user = UserMessage(text: "hi")
    let optimistic = Row(
      id: .message(user.id), content: .optimistic(user, showsStartingAgent: false), estimatedHeight: 1)
    let settledUser = Row(
      id: .message(user.id), content: .message(.user(user), waitingOnBackgroundTask: nil), estimatedHeight: 1)
    let status = Row(id: .error, content: .error("x"), estimatedHeight: 1)

    #expect(TranscriptSendAnimationContract.isEligibleTarget(optimistic, for: .optimistic))
    #expect(TranscriptSendAnimationContract.isEligibleTarget(settledUser, for: .optimistic))
    #expect(!TranscriptSendAnimationContract.isEligibleTarget(status, for: .optimistic))
  }

  @Test func activeTurnTargetsOnlyTheSettledUserMessage() {
    let user = UserMessage(text: "hi")
    let optimistic = Row(
      id: .message(user.id), content: .optimistic(user, showsStartingAgent: false), estimatedHeight: 1)
    let settledUser = Row(
      id: .message(user.id), content: .message(.user(user), waitingOnBackgroundTask: nil), estimatedHeight: 1)

    #expect(!TranscriptSendAnimationContract.isEligibleTarget(optimistic, for: .activeTurn))
    #expect(TranscriptSendAnimationContract.isEligibleTarget(settledUser, for: .activeTurn))
  }
}
