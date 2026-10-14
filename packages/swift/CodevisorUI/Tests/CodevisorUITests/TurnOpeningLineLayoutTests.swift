#if canImport(AppKit)
  import ACPKit
  import AppKit
  import CodevisorCore
  import SwiftUI
  import Testing
  @testable import CodevisorUI

  @Suite("Turn opening line layout")
  @MainActor
  struct TurnOpeningLineLayoutTests {
    @Test("Every opening line state is exactly as tall as the worked header that replaces it")
    func openingLineMatchesHeader() {
      let start = Date(timeIntervalSince1970: 100)
      let fresh = AssistantTurn(isGenerating: true, startedAt: start)
      var retrying = fresh
      retrying.retryStatus = RetryStatus(attempt: 1, of: 3, message: "Retrying")
      var compacting = fresh
      compacting.entries = [.contextCompaction(id: "compact", status: .started)]
      var answering = fresh
      answering.entries = [.text(id: "answer", markdown: "Hi")]
      var working = fresh
      working.entries = [.tool(ToolCall(toolCallId: "ls", title: "Ran ls", kind: .execute, status: .completed))]

      let headers = [answering, working].map {
        height(TranscriptWorkedSectionHeaderView(turn: $0, messageID: UUID(), kind: .planning))
      }
      let openingLines = [fresh, retrying, compacting].map { turn in
        height(
          AssistantTurnActivitySlot(
            AssistantTurnActivity.resolve(
              turn: turn, isWaitingOnUser: false, sessionActivity: nil, backgroundTask: nil, goalActivity: nil),
            turn: turn))
      }
      let newChat = height(TranscriptStartingWorkedHeader(startedAt: start))

      #expect(Set(headers).count == 1)
      #expect(openingLines.allSatisfy { $0 == headers[0] })
      #expect(newChat == headers[0])
    }

    private func height<V: View>(_ view: V) -> CGFloat {
      let host = NSHostingView(rootView: view.frame(width: 600, alignment: .leading))
      host.layoutSubtreeIfNeeded()
      return host.fittingSize.height
    }
  }
#endif
