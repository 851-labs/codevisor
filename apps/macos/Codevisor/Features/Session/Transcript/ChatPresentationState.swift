import CodevisorCore
import CodevisorUI
import Foundation
import Observation

@MainActor
@Observable
final class ChatPresentationState {
  var isAtBottom: Bool
  var autoFollow: Bool
  var earlierHistoryCollapse: TranscriptEarlierHistoryCollapse?
  var scrollCommand = TranscriptScrollCommand()
  var isTranscriptMounted = false
  var isInitialTranscriptReady = false

  init(scrollState: SessionScrollState?) {
    isAtBottom = scrollState?.isAtBottom ?? true
    autoFollow = scrollState?.followMode.followsLatest ?? true
  }

  func forgetMount() {
    if isTranscriptMounted { isTranscriptMounted = false }
    if isInitialTranscriptReady { isInitialTranscriptReady = false }
  }
}
