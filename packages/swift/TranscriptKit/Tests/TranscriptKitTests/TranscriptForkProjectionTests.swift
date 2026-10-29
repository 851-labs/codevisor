import ACPKit
import CodevisorProtocol
import Foundation
import Testing
@testable import TranscriptKit

struct TranscriptForkProjectionTests {
  @Test("A fork marker shows as a marker row, not as something the user said")
  func forkMarkerRow() throws {
    let marker = UserMessage(text: "Forked from Weather", isForkMarker: true)
    let next = UserMessage(text: "Now try Paris")

    let rows = try TranscriptRowProjectionCache.project(
      TranscriptProjectionInput(
        settledConversation: [.user(marker), .user(next)],
        pendingUserMessage: nil,
        activeItem: nil,
        setupPhases: [],
        waitingBackgroundTaskDescription: nil,
        waitingHarnessUpdateName: nil,
        isLoadingInitialHistory: false,
        serverWaitMessage: nil,
        sessionErrorMessage: nil,
        status: .idle
      ),
      options: .init(includesConnectingRow: false)
    )

    #expect(rows.first?.id == .forkMarker(marker.id))
    #expect(rows.first?.content == .forkMarker("Forked from Weather"))
    #expect(rows.filter(\.isUserMessage).map(\.id) == [.message(next.id)])
    #expect(ConversationItem.user(marker).userPrompt == nil)
  }
}
