import CodevisorUI
import CodevisorCore
import SwiftUI

struct PresentedTurnAttentionModifier: ViewModifier {
  @Bindable var controller: SessionController
  let presentationRole: TranscriptPresentationRole

  @Environment(\.scenePhase) private var scenePhase
  @Environment(AppEnvironment.self) private var environment
  @State private var turnStartAttentionSequence: Int?

  func body(content: Content) -> some View {
    content
      .onAppear {
        rememberTurnStartIfNeeded()
      }
      .onChange(of: presentationRole) {
        rememberTurnStartIfNeeded()
      }
      .onChange(of: controller.isSending) { _, isSending in
        if isSending { rememberTurnStartIfNeeded() }
      }
      .onChange(of: controller.liveTurnEndRevision) {
        acknowledgeTurnEndIfNeeded()
      }
      .onChange(of: scenePhase, initial: true) { _, phase in
        if phase == .active { rememberTurnStartIfNeeded() }
      }
      .onDisappear {
        turnStartAttentionSequence = nil
      }
  }

  private func acknowledgeTurnEndIfNeeded() {
    guard presentationRole == .foreground,
      scenePhase == .active,
      let session = controller.serverSession,
      let startSequence = turnStartAttentionSequence
    else { return }
    turnStartAttentionSequence = nil
    environment.projectList.acknowledgePresentedTurnEnd(
      session.id,
      serverId: session.serverId,
      throughSequence: startSequence + 1
    )
  }

  private func rememberTurnStartIfNeeded() {
    guard turnStartAttentionSequence == nil,
      presentationRole == .foreground,
      scenePhase == .active,
      controller.isSending,
      let session = controller.serverSession,
      let summary = environment.projectList.sessions.first(where: {
        $0.serverId == session.serverId && $0.id == session.id
      })
    else { return }
    turnStartAttentionSequence = summary.latestAttentionSequence
  }
}

extension View {
  func acknowledgesPresentedTurnAttention(
    controller: SessionController,
    presentationRole: TranscriptPresentationRole
  ) -> some View {
    modifier(
      PresentedTurnAttentionModifier(
        controller: controller,
        presentationRole: presentationRole
      ))
  }
}
