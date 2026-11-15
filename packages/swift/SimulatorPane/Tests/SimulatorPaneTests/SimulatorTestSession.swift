import Foundation
import Observation
import ScreenSharing
import ScreenSharingTesting
import ScreenSharingV2

@MainActor
@Observable
final class SimulatorTestSession: ScreenSharingV2StartableSession, ScreenSharingSimulatorSession {
  let host: ScreenSharingLocalViewingHost
  let device: ScreenSharingLocalChannel<ScreenSharingSimulatorMessage>
  var presentsTiles = false
  private(set) var isStarted = false
  @ObservationIgnored var stateOnStart: ScreenSharingSimulatorState?
  @ObservationIgnored private let viewing: ScreenSharingLocalViewingSession
  @ObservationIgnored private let channel: ScreenSharingLocalChannel<ScreenSharingSimulatorMessage>

  init() {
    (viewing, host) = ScreenSharingLocalViewingSession.connected()
    (channel, device) = ScreenSharingLocalChannel<ScreenSharingSimulatorMessage>.pair(hop: { work in
      MainActor.assumeIsolated { work() }
    })
  }

  var simulator: any ScreenSharingMessageChannel<ScreenSharingSimulatorMessage> { channel }
  var capabilities: ScreenSharingCapabilities { viewing.capabilities }
  var frames: ScreenSharingFrameMailbox { viewing.frames }
  var metrics: ScreenSharingMetrics { viewing.metrics }
  var control: (any ScreenSharingMessageChannel<ScreenSharingControlMessage>)? { viewing.control }
  var clipboard: (any ScreenSharingMessageChannel<ScreenSharingClipboardMessage>)? { viewing.clipboard }
  var failure: String? { viewing.failure }
  var isClosed: Bool { viewing.isClosed }

  var onConnectionChanged: ((String) -> Void)? {
    get { viewing.onConnectionChanged }
    set { viewing.onConnectionChanged = newValue }
  }

  func start(token: String) async throws {
    if let stateOnStart { device.send(.state(stateOnStart)) }
    isStarted = true
  }

  func statistics() async -> [String: String] { await viewing.statistics() }

  func close() {
    viewing.close()
    channel.close()
  }
}
