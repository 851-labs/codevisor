import Foundation

extension SessionController {
  static let sandboxWakeFailure = "The sandbox didn’t wake up. Try again in a moment."

  public var sandboxPower: SandboxPower? {
    machines?.sandboxPower(forMachineId: project.serverId)?.power
  }

  var transcriptSandboxPower: TranscriptSandboxPower? {
    switch sandboxPower {
    case .paused?: hasUnsentMessages || isReconnectingAfterWake ? .waking : .paused(wakeFailure: sandboxWakeFailure)
    case .waking?: .waking
    case nil: isReconnectingAfterWake ? .waking : nil
    }
  }

  public var isAwaitingInitialHistory: Bool {
    isLoadingInitialHistory && transcriptSandboxPower == nil
  }

  public func wakeSandbox() async {
    guard !isReconnectingAfterWake else { return }
    sandboxWakeFailure = nil
    isReconnectingAfterWake = true
    defer { isReconnectingAfterWake = false }
    do {
      try await machines?.wakeSandbox(forMachineId: project.serverId)
    } catch {
      sandboxWakeFailure = "Couldn’t wake it. \(error.localizedDescription)"
      return
    }
    await reconnectOnceAwake()
  }

  private func reconnectOnceAwake() async {
    for delay in Self.wakeReconnectDelays {
      guard await ObservedState.first({ self.wakeOutcome }) == true else { return }
      guard (try? await Task.sleep(for: delay)) != nil else { return }

      await retrySessionFailure()
      if configurationValidationState == .ready { return }
    }
  }

  private static let wakeReconnectDelays: [Duration] = [
    .zero, .seconds(2), .seconds(5), .seconds(10), .seconds(15), .seconds(30), .seconds(30), .seconds(60),
  ]

  private var wakeOutcome: Bool? {
    if sandboxPower == .paused { return false }
    return sandboxPower == nil && isServerReady ? true : nil
  }

  func wakeSandboxForSend() {
    guard sandboxPower != nil else { return }
    Task { await wakeSandbox() }
  }
}
