import CoreGraphics
import Foundation
import ScreenSharingV2

@MainActor
struct SimulatorStreamHostDependencies {
  var isLoaded: @MainActor () -> Bool
  var isBooted: @MainActor (_ udid: String) throws -> Bool
  var openDevice: @MainActor (_ udid: String) throws -> any SimulatorStreamDevice
  var makePeer:
    @MainActor (_ size: CGSize, _ media: ScreenSharingStreamMedia, _ chroma: String?) throws -> any SimulatorStreamPeer
  var offersV2: @MainActor () -> Bool
  var hostKey: @MainActor () async -> String?
  var now: @MainActor () -> TimeInterval
  var sleep: @Sendable (Duration) async -> Void

  static var live: Self {
    Self(
      isLoaded: { SimulatorRuntime.loaded },
      isBooted: { SimulatorRuntime.isBooted(try SimulatorRuntime.device(udid: $0)) },
      openDevice: { try SimulatorLiveDevice(udid: $0) },
      makePeer: { size, media, chroma in
        try SimulatorV2Peer(size: size, viewerEndpointId: media.viewerEndpointId, encoder: .forViewer(chroma: chroma))
      },
      offersV2: { ScreenSharingMediaEndpoint.shared.isAvailable },
      hostKey: { await ScreenSharingStreamIdentity.mediaEndpointKey() },
      now: { ProcessInfo.processInfo.systemUptime },
      sleep: { try? await Task.sleep(for: $0) })
  }
}
