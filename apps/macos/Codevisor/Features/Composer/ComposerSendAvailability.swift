import CodevisorCore

struct ComposerSendAvailability {
  let controller: SessionController
  let hasDraft: Bool
  let hasSlashMatches: Bool
  let isAppUpdateInProgress: Bool

  var isEnabled: Bool {
    guard !isAppUpdateInProgress else { return false }
    return controller.isGoalComposerArmed ? canSubmitGoal : controller.canSend || hasSlashMatches
  }

  var help: String {
    if isAppUpdateInProgress { return "Updating… you can send once the update finishes." }
    if let sandboxHelp { return sandboxHelp }
    guard controller.isGoalComposerArmed else {
      return controller.canSend || !hasDraft ? "Send (↩)" : "Connecting… you can send once the machine is ready."
    }
    if controller.isPausedForUpdate { return "\(controller.updatingName) is updating" }
    if hasSubmittableContent && controller.isConnectingToHarness { return "Connecting to harness…" }
    if controller.isConnecting { return "Connecting… you can send once the agent is ready." }
    return controller.requiresModelSelection ? "Select a model" : "Send (↩)"
  }

  private var sandboxHelp: String? {
    switch controller.sandboxTargetAvailability {
    case .checking: "Checking the sandbox… you can send once it's ready."
    case .unavailable, .full: controller.sandboxUnavailableMessage
    case .available, nil: nil
    }
  }

  private var hasSubmittableContent: Bool {
    controller.isGoalComposerArmed
      ? !controller.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      : hasDraft || hasSlashMatches
  }

  private var canSubmitGoal: Bool {
    hasSubmittableContent
      && controller.isServerReady
      && !controller.isPausedForUpdate
      && (controller.isConnected || controller.selectedHarness != nil)
      && !controller.isConnecting
      && !controller.isConnectingToHarness
      && !controller.requiresModelSelection
  }
}
