import ScreenSharing

@MainActor
final class SignalingControlChannel: ScreenSharingMessageChannel {
  var onMessage: ((ScreenSharingControlMessage) -> Void)?
  var onAvailabilityChanged: ((Bool) -> Void)?
  private let connection: SignalingConnection
  private var closed = false
  private var reading: Task<Void, Never>?

  init(_ connection: SignalingConnection) {
    self.connection = connection
  }

  var isAvailable: Bool {
    !closed
  }

  @discardableResult
  func send(_ message: ScreenSharingControlMessage) -> Bool {
    guard !closed else { return false }

    do {
      try connection.send(message)
      return true
    } catch {
      close()
      return false
    }
  }

  func close() {
    guard !closed else { return }

    closed = true
    onAvailabilityChanged?(false)
  }

  func startReceiving() {
    guard reading == nil else { return }

    reading = Task { await receiveUntilClosed() }
  }

  func waitUntilClosed() async {
    startReceiving()
    await reading?.value
  }

  private func receiveUntilClosed() async {
    while !closed, let message = await Self.next(from: connection) {
      onMessage?(message)
    }
    close()
  }

  @concurrent
  private static func next(from connection: SignalingConnection) async -> ScreenSharingControlMessage? {
    try? connection.receive(ScreenSharingControlMessage.self)
  }
}
