import ScreenSharing
import ComposableArchitecture
import Foundation

@CasePathable
public enum ScreenSharingControlEvent: Equatable, Sendable {
  case availability(Bool)
  case inputLost(String?)
  case inputNotice(String)
  case message(ScreenSharingControlMessage)
  case sessionFailed(String)
}

@DependencyClient
public struct ScreenSharingEndpointClient: Sendable {
  public var beginInput: @Sendable (_ endpoint: ScreenSharingViewerEndpoint.ID, _ lease: UUID) async -> String? = {
    _, _ in nil
  }
  public var controlEvents:
    @Sendable (_ endpoint: ScreenSharingViewerEndpoint.ID) async -> AsyncStream<ScreenSharingControlEvent> = { _ in
      .finished
    }
  public var endInput: @Sendable (_ endpoint: ScreenSharingViewerEndpoint.ID) async -> Void
  public var sendControl:
    @Sendable (_ endpoint: ScreenSharingViewerEndpoint.ID, _ message: ScreenSharingControlMessage) async -> Bool = {
      _, _ in false
    }
  public var tapSystemKey:
    @Sendable (_ endpoint: ScreenSharingViewerEndpoint.ID, _ key: ScreenSharingSystemKey) async -> Void = { _, _ in }
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
      tapSystemKey: { id, key in await ScreenSharingEndpointRegistry.shared.endpoint(id)?.tap(key) },
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

@MainActor
final class ScreenSharingEndpointRegistry {
  static let shared = ScreenSharingEndpointRegistry()
  private var endpoints: [ScreenSharingViewerEndpoint.ID: ScreenSharingViewerEndpoint] = [:]

  func register(_ endpoint: ScreenSharingViewerEndpoint) { endpoints[endpoint.id] = endpoint }
  func unregister(_ id: ScreenSharingViewerEndpoint.ID) { endpoints[id] = nil }
  func endpoint(_ id: ScreenSharingViewerEndpoint.ID) -> ScreenSharingViewerEndpoint? { endpoints[id] }
}
