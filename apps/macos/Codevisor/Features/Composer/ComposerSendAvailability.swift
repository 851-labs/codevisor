import CodevisorCore

struct ComposerSendAvailability {
  let controller: SessionController
  let hasDraft: Bool
  let hasSlashMatches: Bool
  let isAppUpdateInProgress: Bool

  var isEnabled: Bool {
    !isAppUpdateInProgress
      && controller.isServerReady
      && !controller.isPausedForUpdate
      && (controller.isGoalComposerArmed ? canSubmitGoal : canSendMessage)
  }

  var help: String {
    if isAppUpdateInProgress { return "Updating… you can send once the update finishes." }
    if controller.isPausedForUpdate { return "\(controller.updatingName) is updating" }
    if hasSubmittableContent && controller.isConnectingToHarness { return "Connecting to harness…" }
    if controller.isConnecting { return "Connecting… you can send once the agent is ready." }
    return controller.requiresModelSelection ? "Select a model" : "Send (↩)"
  }

  private var hasSubmittableContent: Bool {
    controller.isGoalComposerArmed
      ? !controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      : hasDraft || hasSlashMatches
  }

  private var canSubmitGoal: Bool {
    hasSubmittableContent
      && (controller.isConnected || controller.selectedHarness != nil)
      && !controller.isConnecting
      && !controller.isConnectingToHarness
      && !controller.requiresModelSelection
  }

  private var canSendMessage: Bool {
    !controller.isConnectingToHarness && (controller.canSend || hasSlashMatches)
  }
}
