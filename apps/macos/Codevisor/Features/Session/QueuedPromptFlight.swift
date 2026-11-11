import AppKit
import CodevisorCore
import CodevisorUI

@MainActor
enum QueuedPromptFlight {
  static func install(on controller: SessionController) {
    controller.onQueuedPromptWillFly = { [weak controller] messageID in
      guard let controller, !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
      let style: UserBubbleStyle = controller.presentsBotConversation ? .accent : .standard
      TranscriptQueueSendSources.shared.stageFlight(
        for: messageID,
        session: ObjectIdentifier(controller),
        bubble: style.fill,
        revealsBubbleInFlight: style == .accent
      )
    }
  }
}
