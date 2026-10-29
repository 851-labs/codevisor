import CoreMedia
import ScreenCaptureKit
import ScreenSharingBench
import Synchronization

final class FrameCollector: NSObject, SCStreamOutput, SCStreamDelegate, Sendable {
  let queue = DispatchQueue(label: "CodevisorBench observer", qos: .userInteractive)
  let continuousMinusAbsoluteNs = BenchMachClock.continuousMinusAbsoluteNs()
  private let layout: BenchBarcodeLayout
  private let relay: VersionRelay?
  private let observations = Mutex<[BenchObservation]>([])
  private let failure = Mutex<(any Error)?>(nil)

  init(layout: BenchBarcodeLayout, relay: VersionRelay?) {
    self.layout = layout
    self.relay = relay
  }

  func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
    let callbackNs = BenchMachClock.nowNs()
    guard type == .screen else { return }

    do {
      guard
        let observation = try BenchCapturedFrame.observation(
          of: sampleBuffer, layout: layout, callbackNs: callbackNs, continuousMinusAbsoluteNs: continuousMinusAbsoluteNs
        )
      else { return }

      observations.withLock { $0.append(observation) }
      relay?.forward(observation)
    } catch {
      failure.withLock { $0 = $0 ?? error }
    }
  }

  func stream(_ stream: SCStream, didStopWithError error: any Error) {
    failure.withLock { $0 = $0 ?? error }
  }

  func collected() throws -> [BenchObservation] {
    if let error = failure.withLock({ $0 }) { throw error }

    return observations.withLock { $0 }
  }
}
