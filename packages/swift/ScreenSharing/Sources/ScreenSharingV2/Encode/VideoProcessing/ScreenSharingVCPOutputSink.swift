import CoreMedia
import Dispatch
import Synchronization
import VideoToolbox

final class ScreenSharingVCPOutputSink: Sendable {
  typealias Handler = @Sendable (ScreenSharingVCPOutput) -> Void

  static let callback: VTCompressionOutputCallback = { refcon, frameRefcon, status, flags, sample in
    guard let refcon else { return }

    let sink = Unmanaged<ScreenSharingVCPOutputSink>.fromOpaque(refcon).takeUnretainedValue()
    sink.receive(
      ScreenSharingVCPOutput(
        submission: UInt64(UInt(bitPattern: frameRefcon)), status: status, flags: flags, sample: sample))
  }

  private struct Receiver {
    var handler: Handler?
  }

  private let receiver = Mutex(Receiver())
  private let queue = DispatchQueue(label: "codevisor.screen-sharing.vcp.output", qos: .userInteractive)

  func onOutput(_ handler: Handler?) {
    receiver.withLock { $0.handler = handler }
  }

  private func receive(_ output: ScreenSharingVCPOutput) {
    queue.async { [self] in receiver.withLock { $0.handler }?(output) }
  }
}
