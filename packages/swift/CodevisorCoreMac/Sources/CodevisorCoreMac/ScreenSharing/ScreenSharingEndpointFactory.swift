import CodevisorClient
import Foundation
import OSLog
import ScreenSharing
import ScreenSharingConnection

@MainActor
struct ScreenSharingEndpointFactory {
  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")

  let machineId: String
  let source: ScreenSharingConnectionsSource

  func endpoint(for session: any ScreenSharingViewingSession, displayId: String?) -> ScreenSharingViewerEndpoint? {
    let (machineId, makeSurface) = (machineId, source.makeSurface)
    let endpoint = ScreenSharingViewerEndpoint(session: session, sound: false, displayId: displayId) {
      frames, metrics in
      do {
        return try makeSurface(frames, metrics)
      } catch {
        Self.logger.error("Couldn't show the desktop of \(machineId, privacy: .public): \(error, privacy: .public)")
        throw error
      }
    }
    configure(endpoint, for: session, displayId: displayId)
    return endpoint
  }

  private func configure(
    _ endpoint: ScreenSharingViewerEndpoint, for session: any ScreenSharingViewingSession, displayId: String?
  ) {
    guard session is VNCScreenSharingSession else {
      endpoint.dropsInjectedInput = displayId.map(ScreenSharingDisplayIdentity.isOnThisMac) ?? false
      return
    }

    endpoint.dropsInjectedInput = false
    guard let displayId else { return }

    endpoint.setDesktopScale = { [channel = source.channel, machineId] scale in
      var request = ServerScreenSharingRequest(
        operation: .setScale, workspaceId: UUID(), paneId: UUID(), viewerId: UUID(), displayId: displayId)
      request.scale = scale
      _ = try? await channel(machineId).send(request)
    }
  }
}
