import CodevisorClient
import Foundation

@MainActor
final class CloudLocalMachineRegistration {
  struct Resolution: Sendable {
    let deviceId: String
    let didConnect: Bool
  }

  private(set) var task: Task<Resolution?, Never>?
  private(set) var deregistrationTask: Task<Void, Never>?

  func begin(
    for account: CloudAccountController,
    token: String,
    localClient: any CodevisorServerClienting
  ) -> Task<Resolution?, Never> {
    if let task { return task }
    let serverURL = account.serverURL
    let task: Task<Resolution?, Never> = Task { [weak self, weak account] in
      guard let self, let account else { return nil }
      defer { self.task = nil }
      guard let resolution = await Self.resolve(token: token, serverURL: serverURL, localClient: localClient),
        !Task.isCancelled
      else { return nil }
      account.onLocalMachineRegistrationResolved?(resolution.deviceId)
      return resolution
    }
    self.task = task
    return task
  }

  func registerIfIdle(
    for account: CloudAccountController,
    token: String,
    localClient: any CodevisorServerClienting
  ) {
    guard task == nil else { return }
    let registration = begin(for: account, token: token, localClient: localClient)
    Task { [weak account] in
      guard let resolution = await registration.value,
        resolution.didConnect,
        !Task.isCancelled,
        let account
      else { return }
      await account.refreshMachines()
    }
  }

  func cancel() {
    task?.cancel()
    task = nil
  }

  func deregister(
    token: String?,
    localClient: any CodevisorServerClienting,
    accountClient: any CloudAccountClienting
  ) {
    deregistrationTask = Task {
      do {
        let registration = try await localClient.cloudRegistration()
        guard let deviceId = Self.appManagedDeviceId(registration) else { return }
        try await localClient.disconnectCloud()
        if let token {
          try? await accountClient.removeMachine(deviceId: deviceId, token: token)
        }
        Log.cloud.log("Deregistered this machine from the cloud account on sign-out")
      } catch {
        Log.cloud.error(
          "Local machine cloud deregistration failed: \(String(describing: error), privacy: .public)")
      }
    }
  }

  private static func resolve(
    token: String,
    serverURL: URL,
    localClient: any CodevisorServerClienting
  ) async -> Resolution? {
    do {
      let current = try await localClient.cloudRegistration()
      guard let registration = try await replacingRevoked(current, localClient: localClient) else { return nil }
      return try await resolution(for: registration, token: token, serverURL: serverURL, localClient: localClient)
    } catch {
      Log.cloud.debug(
        "Local machine cloud registration skipped: \(String(describing: error), privacy: .public)"
      )
      return nil
    }
  }

  private static func replacingRevoked(
    _ registration: ServerCloudRegistration,
    localClient: any CodevisorServerClienting
  ) async throws -> ServerCloudRegistration? {
    guard isRevokedAppRegistration(registration) else { return registration }
    guard !Task.isCancelled else { return nil }
    try await localClient.disconnectCloud()
    return try await localClient.cloudRegistration()
  }

  private static func resolution(
    for registration: ServerCloudRegistration,
    token: String,
    serverURL: URL,
    localClient: any CodevisorServerClienting
  ) async throws -> Resolution? {
    guard !registration.connected else { return existingResolution(registration) }
    guard !Task.isCancelled else { return nil }
    let deviceId = try await localClient.connectCloud(serverURL: serverURL, sessionToken: token)
    Log.cloud.log("Registered this machine on the cloud account as \(deviceId, privacy: .public)")
    return Resolution(deviceId: deviceId, didConnect: true)
  }

  private nonisolated static func existingResolution(_ registration: ServerCloudRegistration) -> Resolution? {
    guard let deviceId = registration.deviceId else {
      Log.cloud.debug("Connected local cloud registration did not report a device id")
      return nil
    }
    return Resolution(deviceId: deviceId, didConnect: false)
  }

  private nonisolated static func isRevokedAppRegistration(_ registration: ServerCloudRegistration) -> Bool {
    registration.connected && registration.state == "revoked" && registration.managedBy == "app"
  }

  private nonisolated static func appManagedDeviceId(_ registration: ServerCloudRegistration) -> String? {
    guard registration.managedBy == "app" else { return nil }
    return registration.deviceId
  }
}
