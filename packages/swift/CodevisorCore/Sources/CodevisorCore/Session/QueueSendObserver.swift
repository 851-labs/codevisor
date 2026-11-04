@MainActor
public struct QueueSendObserver {
  private struct Mark: Equatable {
    let controller: ObjectIdentifier
    let queueSendSignal: Int
  }

  private var lastMark: Mark?

  public init() {}

  public mutating func sentSinceLastCheck(in controller: SessionController) -> Bool {
    let mark = Mark(controller: ObjectIdentifier(controller), queueSendSignal: controller.queueSendSignal)
    defer { lastMark = mark }
    guard let lastMark, lastMark.controller == mark.controller else { return false }

    return lastMark.queueSendSignal != mark.queueSendSignal
  }
}
