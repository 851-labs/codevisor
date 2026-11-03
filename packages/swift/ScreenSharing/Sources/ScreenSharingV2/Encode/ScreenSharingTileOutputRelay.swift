import Foundation

final class ScreenSharingTileOutputRelay: @unchecked Sendable {
  private let lock = NSLock()
  private var handler: (@Sendable (ScreenSharingTileEncoderOutput) -> Void)?

  func set(_ output: (@Sendable (ScreenSharingTileEncoderOutput) -> Void)?) {
    lock.withLock { handler = output }
  }

  func emit(_ output: ScreenSharingTileEncoderOutput) {
    lock.withLock { handler }?(output)
  }
}
