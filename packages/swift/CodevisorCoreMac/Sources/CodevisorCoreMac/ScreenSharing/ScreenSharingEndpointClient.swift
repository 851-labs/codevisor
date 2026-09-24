import ScreenSharing
import ComposableArchitecture
import Foundation

/// Control-plane events one endpoint reports: its control channel's state and
/// messages, the loss of input capture, and a terminal session failure. Input
/// events themselves never appear here; they stay on the data plane.
@CasePathable
public enum ScreenSharingControlEvent: Equatable, Sendable {
  case availability(Bool)
  /// The surface can no longer capture input, or the channel could not carry it.
  case inputLost(String?)
  case message(ScreenSharingControlMessage)
  /// The media session failed terminally (today: the hardware decoder).
  case sessionFailed(String)
}

/// What the viewer's reducers ask of a live endpoint, keyed by endpoint id so
/// the reducers hold values only. The live client resolves ids through the
/// registry every endpoint joins when created and leaves when closed; tests
/// script the closures directly.
@DependencyClient
public struct ScreenSharingEndpointClient: Sendable {
  /// Starts forwarding input under `lease`; the failure message when the surface cannot capture.
  public var beginInput: @Sendable (_ endpoint: ScreenSharingViewerEndpoint.ID, _ lease: UUID) async -> String? = {
    _, _ in nil
  }
  /// Availability first, then messages, input loss and session failure, until the endpoint closes.
  public var controlEvents:
    @Sendable (_ endpoint: ScreenSharingViewerEndpoint.ID) async -> AsyncStream<ScreenSharingControlEvent> = { _ in
      .finished
    }
  public var endInput: @Sendable (_ endpoint: ScreenSharingViewerEndpoint.ID) async -> Void
  public var sendControl:
    @Sendable (_ endpoint: ScreenSharingViewerEndpoint.ID, _ message: ScreenSharingControlMessage) async -> Bool = {
      _, _ in false
    }
  /// Dynamic Resolution on or off (851-2340); with the display's details when known: the size
  /// turning it off restores ([width, height]) and whether its desktop can draw at 2×.
  public var setDynamicResolution:
    @Sendable (
      _ endpoint: ScreenSharingViewerEndpoint.ID, _ enabled: Bool, _ defaultSize: [Int]?, _ canScale: Bool?
    ) async -> Void = { _, _, _, _ in }
}

extension ScreenSharingEndpointClient: DependencyKey {
  public static var liveValue: Self {
    Self(
      beginInput: { id, lease in await ScreenSharingEndpointRegistry.shared.endpoint(id)?.beginInput(lease: lease) },
      controlEvents: { id in await ScreenSharingEndpointRegistry.shared.endpoint(id)?.controlEvents() ?? .finished },
      endInput: { id in await ScreenSharingEndpointRegistry.shared.endpoint(id)?.endInput() },
      sendControl: { id, message in
        await ScreenSharingEndpointRegistry.shared.endpoint(id)?.sendControl(message) ?? false
      },
      setDynamicResolution: { id, enabled, defaultSize, canScale in
        guard let endpoint = await ScreenSharingEndpointRegistry.shared.endpoint(id) else { return }
        await MainActor.run {
          if let defaultSize, defaultSize.count == 2 { endpoint.defaultDesktopSize = (defaultSize[0], defaultSize[1]) }
          if let canScale { endpoint.desktopCanScale = canScale }
          endpoint.setDynamicResolution(enabled)
        }
      })
  }

  public static var testValue: Self { Self() }
}

/// Live endpoints by id. An endpoint registers itself when created and
/// unregisters when closed, so a stale id resolves to nothing rather than to
/// a torn-down endpoint.
@MainActor
final class ScreenSharingEndpointRegistry {
  static let shared = ScreenSharingEndpointRegistry()
  private var endpoints: [ScreenSharingViewerEndpoint.ID: ScreenSharingViewerEndpoint] = [:]

  func register(_ endpoint: ScreenSharingViewerEndpoint) { endpoints[endpoint.id] = endpoint }
  func unregister(_ id: ScreenSharingViewerEndpoint.ID) { endpoints[id] = nil }
  func endpoint(_ id: ScreenSharingViewerEndpoint.ID) -> ScreenSharingViewerEndpoint? { endpoints[id] }
}
