import ScreenSharing
import ComposableArchitecture
import Foundation
@testable import CodevisorCoreMac

/// A scripted `ScreenSharingEndpointClient`: records every call by endpoint
/// id and lets a test push control events into any endpoint's stream, also
/// before the reducer subscribes (the stream buffers).
@MainActor
final class FakeEndpointClient {
  private(set) var beginInputs: [(endpoint: ScreenSharingViewerEndpoint.ID, lease: UUID)] = []
  private(set) var endInputs: [ScreenSharingViewerEndpoint.ID] = []
  private(set) var sent: [(endpoint: ScreenSharingViewerEndpoint.ID, message: ScreenSharingControlMessage)] = []
  /// Dynamic Resolution calls (851-2340): on/off and the default size passed.
  private(set) var dynamicResolutions:
    [(endpoint: ScreenSharingViewerEndpoint.ID, enabled: Bool, defaultSize: [Int]?)] =
      []
  /// The failure `beginInput` reports; nil grants capture.
  var beginInputFailure: String?
  /// What `sendControl` answers.
  var sendSucceeds = true
  private var streams:
    [ScreenSharingViewerEndpoint.ID: (
      AsyncStream<ScreenSharingControlEvent>, AsyncStream<ScreenSharingControlEvent>.Continuation
    )] = [:]

  func messages(to endpoint: ScreenSharingViewerEndpoint.ID) -> [ScreenSharingControlMessage] {
    sent.filter { $0.endpoint == endpoint }.map(\.message)
  }

  func emit(_ event: ScreenSharingControlEvent, to endpoint: ScreenSharingViewerEndpoint.ID) {
    stream(for: endpoint).1.yield(event)
  }

  func finish(_ endpoint: ScreenSharingViewerEndpoint.ID) { stream(for: endpoint).1.finish() }

  var value: ScreenSharingEndpointClient {
    ScreenSharingEndpointClient(
      beginInput: { [self] endpoint, lease in
        await MainActor.run {
          beginInputs.append((endpoint, lease))
          return beginInputFailure
        }
      },
      controlEvents: { [self] endpoint in await MainActor.run { stream(for: endpoint).0 } },
      endInput: { [self] endpoint in await MainActor.run { endInputs.append(endpoint) } },
      sendControl: { [self] endpoint, message in
        await MainActor.run {
          sent.append((endpoint, message))
          return sendSucceeds
        }
      },
      setDynamicResolution: { [self] endpoint, enabled, defaultSize, _ in
        await MainActor.run { dynamicResolutions.append((endpoint, enabled, defaultSize)) }
      })
  }

  private func stream(
    for endpoint: ScreenSharingViewerEndpoint.ID
  ) -> (AsyncStream<ScreenSharingControlEvent>, AsyncStream<ScreenSharingControlEvent>.Continuation) {
    if let existing = streams[endpoint] { return existing }
    let made = AsyncStream<ScreenSharingControlEvent>.makeStream()
    streams[endpoint] = (made.stream, made.continuation)
    return (made.stream, made.continuation)
  }
}
