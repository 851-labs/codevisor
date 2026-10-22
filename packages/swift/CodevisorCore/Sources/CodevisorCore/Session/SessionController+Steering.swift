import Foundation

extension SessionController {
  public var supportsSteering: Bool {
    guard let harnessId = connectedHarnessId ?? selectedHarnessId else { return false }
    return supportsSteeringByHarness[harnessId] ?? false
  }

  public var canQueueMessages: Bool {
    isSending && !presentsBotConversation
  }

  public var steersWhileWorking: Bool {
    canQueueMessages && supportsSteering
  }

  public var canSendQueuedPromptNow: Bool {
    supportsSteering && !presentsBotConversation && !isPausedForUpdate
  }

  public func sendLandsInQueue(_ delivery: ServerPromptDelivery) -> Bool {
    guard canQueueMessages else { return false }
    return delivery == .queue || !supportsSteering
  }

  @discardableResult
  public func sendQueuedPromptNow(id: String) async -> Bool {
    await model?.promptQueue.sendNow(id: id) ?? false
  }

  func resolvedDelivery(for delivery: ServerPromptDelivery) -> ServerPromptDelivery {
    sendLandsInQueue(delivery) ? .queue : .steer
  }
}
