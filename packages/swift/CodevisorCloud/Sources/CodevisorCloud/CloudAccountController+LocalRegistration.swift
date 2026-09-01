import CodevisorClient
import Foundation

extension CloudAccountController {
    func beginLocalMachineRegistration(
        token: String,
        localClient: any CodevisorServerClienting
    ) -> Task<LocalRegistrationResolution?, Never> {
        if let localRegistrationTask { return localRegistrationTask }
        let serverURL = serverURL
        let task: Task<LocalRegistrationResolution?, Never> = Task { [weak self] in
            guard let self else { return nil }
            defer { self.localRegistrationTask = nil }
            do {
                let registration = try await localClient.cloudRegistration()
                let resolution: LocalRegistrationResolution
                if registration.connected {
                    guard let deviceId = registration.deviceId else {
                        Log.cloud.debug(
                            "Connected local cloud registration did not report a device id"
                        )
                        return nil
                    }
                    resolution = LocalRegistrationResolution(
                        deviceId: deviceId,
                        didConnect: false
                    )
                } else {
                    guard !Task.isCancelled else { return nil }
                    let deviceId = try await localClient.connectCloud(
                        serverURL: serverURL,
                        sessionToken: token
                    )
                    Log.cloud.log(
                        "Registered this machine on the cloud account as \(deviceId, privacy: .public)"
                    )
                    resolution = LocalRegistrationResolution(
                        deviceId: deviceId,
                        didConnect: true
                    )
                }
                guard !Task.isCancelled else { return nil }
                self.onLocalMachineRegistrationResolved?(resolution.deviceId)
                return resolution
            } catch {
                Log.cloud.debug(
                    "Local machine cloud registration skipped: \(String(describing: error), privacy: .public)"
                )
                return nil
            }
        }
        localRegistrationTask = task
        return task
    }
}
