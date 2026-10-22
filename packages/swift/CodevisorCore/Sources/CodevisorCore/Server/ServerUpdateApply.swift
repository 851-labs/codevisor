import Foundation

struct ServerUpdateApply {
  let start: @MainActor (ServerUpdateChannel) async throws -> ServerUpdateApplied

  static func serverOnly(_ client: any CodevisorServerClienting) -> ServerUpdateApply {
    ServerUpdateApply { channel in try await client.applyServerUpdate(channel: channel) }
  }

  static func afterHarnesses(
    _ harnessIds: [String],
    client: any CodevisorServerClienting
  ) -> ServerUpdateApply {
    guard !harnessIds.isEmpty else { return serverOnly(client) }

    return ServerUpdateApply { channel in
      do {
        let request = ServerUpdateRunRequest(harnessIds: harnessIds, serverChannel: channel)
        return try await client.startUpdateRun(request).server ?? declined
      } catch CodevisorServerClientError.httpStatus(404, _) {
        return try await client.applyServerUpdate(channel: channel)
      }
    }
  }

  private static let declined = ServerUpdateApplied(accepted: false, targetVersion: nil)
}
