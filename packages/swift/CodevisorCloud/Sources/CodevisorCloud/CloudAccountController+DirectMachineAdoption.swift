import CodevisorClient
import Foundation

extension CloudAccountController {
  public func adoptDirectMachine(
    using client: any CodevisorServerClienting,
    name: String
  ) async throws -> String {
    guard state.isSignedIn, let token = storedToken else { throw CloudAccountClientError.missingToken }
    let deviceId = try await client.connectCloud(
      serverURL: serverURL,
      sessionToken: token,
      managedBy: "external",
      machineName: name
    )
    Log.cloud.log("Moved a directly paired machine onto the cloud account as \(deviceId, privacy: .public)")
    await refreshMachines()
    return deviceId
  }
}
