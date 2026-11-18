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
  @ObservationIgnored private var observers: Set<UUID> = []

  public init() {}

  func observeFrames(of clock: TranscriptPresentationClock, for observer: UUID) {
    observers.insert(observer)
    if let observation {
      guard observation.clock !== clock else { return }

      observation.clock.removePresentObserver(observation.id)
    }
    let id = clock.addPresentObserver { [weak self] in self?.publishStaged() }
    observation = (clock, id)
  }

  func stopObservingFrames(for observer: UUID) {
    observers.remove(observer)
    guard observers.isEmpty else { return }

    if let observation { observation.clock.removePresentObserver(observation.id) }
    observation = nil
    worker.cancel()
  }

  private func publishStaged() {
    guard let ready = staging.takePublishable() else { return }

    if ready.rows != rows || ready.restorationID != textRestorationID {
      rows = ready.rows
      textRestorationID = ready.restorationID
      rowsVersion &+= 1
    }
    if publishedKey != ready.key { publishedKey = ready.key }
  }
}
