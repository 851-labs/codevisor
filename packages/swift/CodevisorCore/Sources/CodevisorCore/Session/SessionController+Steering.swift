import Foundation

extension SessionController {
  public var supportsSteering: Bool {
    guard let harnessId = connectedHarnessId ?? selectedHarnessId else { return false }
    return supportsSteeringByHarness[harnessId] ?? false
  }

  public var canQueueMessages: Bool {
    isSending && !presentsBotConversation && !isAwaitingAnswer
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

  public func deleteSteer(messageID: UUID) async {
    _ = await model?.withdrawSteer(messageID: messageID)
  }

  public func sendSteerNow(messageID: UUID) async {
    guard let id = model?.awaitingStepQueueItemID(for: messageID) else { return }
    await sendQueuedPromptNow(id: id)
  }

  @discardableResult
  public func sendQueuedPromptNow(id: String) async -> Bool {
    await model?.promptQueue.sendNow(id: id) ?? false
  }

  func resolvedDelivery(for delivery: ServerPromptDelivery) -> ServerPromptDelivery {
    guard canQueueMessages, delivery == .queue || !supportsSteering else { return .steer }
    return .queue
  }
}
