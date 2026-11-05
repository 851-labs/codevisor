import CodevisorCore
import CodevisorUI
import Foundation

struct NewChatSetupFailure {
  let store: SessionStore
  let paneDraftId: UUID?

  func recover(_ controller: SessionController, startedAs session: ChatSession) {
    TranscriptSendStaging.shared.cancel(session: ObjectIdentifier(controller))
    let started = controller.serverSession ?? session
    controller.serverSession = nil
    controller.onAgentSessionCreated = nil
    guard let paneDraftId else {
      returnToNewChatPage(controller, from: started)
      return
    }
    store.restorePaneDraftPersistence(controller, paneId: store.paneDraftLocation(for: started)?.paneId ?? paneDraftId)
  }

  private func returnToNewChatPage(_ controller: SessionController, from started: ChatSession) {
    store.discardUnstartedChat(started)
    store.restoreDraftPersistence(controller)
  }
}
