import CodevisorClient
import Foundation

extension CloudAccountController {
  /// A paired machine participates in the same refresh coordinator as relay
  /// machines. Existing registrations remain under their original owner.
  public func prepareAccountSync(on client: any CodevisorServerClienting, machineId: String) async -> Bool {
    guard state.isSignedIn, let token = storedToken else { return false }
    let server = serverURL
    let key = "\(authenticationRevision):\(server.absoluteString):\(machineId)"
    if let pending = accountSyncRegistrations[key] { return await pending.value }
    let task = Task { [weak self] in
      do {
        let registration = try await client.cloudRegistration()
        guard !registration.connected, let self,
          self.state.isSignedIn, self.storedToken == token, self.serverURL == server,
          !Task.isCancelled
        else { return false }
        _ = try await client.connectCloud(serverURL: server, sessionToken: token)
        return true
      } catch {
        // The normal per-machine account status shows any missing coordinator.
        // The next connection or sync pass retries a failed registration.
        return false
      }
    }
    accountSyncRegistrations[key] = task
    let result = await task.value
    accountSyncRegistrations[key] = nil
    return result
  }
}
