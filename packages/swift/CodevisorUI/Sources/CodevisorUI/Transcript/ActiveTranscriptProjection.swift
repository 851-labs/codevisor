import CodevisorCore
import Foundation
import Observation
import TranscriptKit

@MainActor
@Observable
public final class ActiveTranscriptProjection {
  public private(set) var rows: [TranscriptPresentationRow] = []
  public private(set) var rowsVersion: UInt64 = 0
  public private(set) var textRestorationID: String?
  private(set) var publishedKey: ActiveTranscriptProjectionKey?

  @ObservationIgnored let staging = ActiveTranscriptProjectionStaging()
  @ObservationIgnored let worker = TranscriptActiveProjectionWorker()
  @ObservationIgnored private var observation: (clock: TranscriptPresentationClock, id: UUID)?

  public init() {}

  func observeFrames(of clock: TranscriptPresentationClock) {
    if let observation {
      guard observation.clock !== clock else { return }

      observation.clock.removePresentObserver(observation.id)
    }
    let id = clock.addPresentObserver { [weak self] in self?.publishStaged() }
    observation = (clock, id)
  }

  func stopObservingFrames() {
    if let observation { observation.clock.removePresentObserver(observation.id) }
    observation = nil
    worker.cancel()
  }

  private func publishStaged() {
    guard let ready = staging.takePublishable() else { return }

    rows = ready.rows
    textRestorationID = ready.restorationID
    rowsVersion &+= 1
    publishedKey = ready.key
  }
}
