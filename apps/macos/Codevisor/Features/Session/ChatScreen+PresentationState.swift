import CodevisorUI
import SwiftUI

extension ChatScreen {
  var presentation: ChatPresentationState { presentationSurface.presentation }

  var isAtBottom: Bool {
    get { presentation.isAtBottom }
    nonmutating set {
      if reportsScrollState, presentation.isAtBottom != newValue { presentation.isAtBottom = newValue }
    }
  }

  var autoFollow: Bool {
    get { presentation.autoFollow }
    nonmutating set {
      if reportsScrollState, presentation.autoFollow != newValue { presentation.autoFollow = newValue }
    }
  }

  var earlierHistoryCollapse: TranscriptEarlierHistoryCollapse? {
    get { presentation.earlierHistoryCollapse }
    nonmutating set {
      guard reportsScrollState, presentation.earlierHistoryCollapse != newValue else { return }

      presentation.earlierHistoryCollapse = newValue
    }
  }

  var composerCardHeight: CGFloat {
    get { presentationSurface.composer.cardHeight }
    nonmutating set { presentationSurface.composer.update(cardHeight: newValue) }
  }

  var scrollCommand: TranscriptScrollCommand {
    get { presentation.scrollCommand }
    nonmutating set { if presentation.scrollCommand != newValue { presentation.scrollCommand = newValue } }
  }

  var isTranscriptMounted: Bool {
    get { presentation.isTranscriptMounted }
    nonmutating set { if presentation.isTranscriptMounted != newValue { presentation.isTranscriptMounted = newValue } }
  }

  var isInitialTranscriptReady: Bool {
    get { presentation.isInitialTranscriptReady }
    nonmutating set {
      if presentation.isInitialTranscriptReady != newValue { presentation.isInitialTranscriptReady = newValue }
    }
  }
}
