import Foundation

public enum CodevisorAppVariant: Sendable {
    public static let productionPort = 49_361
    public static let developmentPort = 49_362

    private static var environment: [String: String] {
        ProcessInfo.processInfo.environment
    }

    public static var isDevelopment: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    public static var localServerPort: Int {
        guard isDevelopment else { return productionPort }
        return (environment["CODEVISOR_DEV_PORT"] ?? environment["HERDMAN_DEV_PORT"])
            .flatMap(Int.init) ?? developmentPort
    }

    public static var developmentWorktreeName: String {
        guard isDevelopment else { return "" }
        return environment["CODEVISOR_DEV_WORKTREE"]
            ?? environment["HERDMAN_DEV_WORKTREE"]
            ?? "default"
    }

    public static var developmentInstanceID: String? {
        guard isDevelopment else { return nil }
        return environment["CODEVISOR_DEV_INSTANCE_ID"]
            ?? environment["HERDMAN_DEV_INSTANCE_ID"]
    }

    public static var developmentIconColorHex: String {
        guard isDevelopment else { return "#000000" }
        return environment["CODEVISOR_DEV_ICON_COLOR"] ?? "#0088ff"
    }

    /// A local standalone server that `bun run dev` starts alongside the app,
    /// so remote-machine flows can be developed offline. Present only in
    /// development runs where the dev script provided its details.
    public struct DevelopmentRemote: Sendable, Equatable {
        public let host: String
        public let port: Int
        public let token: String
        public let name: String

        /// Value for MachineController.addRemote (which defaults the port).
        public var hostWithPort: String { "\(host):\(port)" }

        /// A codevisor-dev deeplink that adds this machine, for testing the
        /// deeplink flow by opening it.
        public var deeplink: String {
            var components = URLComponents()
            components.scheme = "codevisor-dev"
            components.host = "add-machine"
            components.queryItems = [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "port", value: String(port)),
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "name", value: name)
            ]
            return components.string ?? ""
        }
    }

    public static var developmentRemote: DevelopmentRemote? {
        guard isDevelopment else { return nil }
        let env = environment
        guard let host = env["CODEVISOR_DEV_REMOTE_HOST"], !host.isEmpty,
              let port = env["CODEVISOR_DEV_REMOTE_PORT"].flatMap(Int.init),
              let token = env["CODEVISOR_DEV_REMOTE_TOKEN"], !token.isEmpty
        else { return nil }
        return DevelopmentRemote(
            host: host,
            port: port,
            token: token,
            name: env["CODEVISOR_DEV_REMOTE_NAME"] ?? "Test Remote"
        )
    }

    public static var applicationSupportDirectoryName: String {
        guard isDevelopment else { return "Codevisor" }
        guard let developmentInstanceID, !developmentInstanceID.isEmpty else {
            return "Codevisor Development"
        }
        return "Codevisor Development/\(developmentInstanceID)"
    }

    public static func applicationSupportURL(fileManager: FileManager = .default) -> URL {
        if isDevelopment,
           let override = environment["CODEVISOR_DEV_DATA_DIR"]
            ?? environment["HERDMAN_DEV_DATA_DIR"],
           !override.isEmpty {
            return createdDirectory(
                at: URL(fileURLWithPath: override, isDirectory: true),
                fileManager: fileManager
            )
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return createdDirectory(
            at: base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true),
            fileManager: fileManager
        )
    }

    /// One-time rescue for the HerdMan → Codevisor rename: the app updates in
    /// place (the bundle id stayed `com.851labs.HerdMan`) but the Application
    /// Support folder name changed, orphaning every file-backed preference in
    /// the old folder. Copies legacy files that don't exist at the new
    /// location yet; never overwrites, and leaves the old folder as a backup.
    public static func migrateLegacyApplicationSupportIfNeeded(fileManager: FileManager = .default) {
        guard !isDevelopment else { return }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        migrateLegacyApplicationSupport(
            from: base.appendingPathComponent("HerdMan", isDirectory: true),
            to: applicationSupportURL(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    static func migrateLegacyApplicationSupport(from legacy: URL, to destination: URL, fileManager: FileManager) {
        guard fileManager.fileExists(atPath: legacy.path) else { return }
        let contents = (try? fileManager.contentsOfDirectory(at: legacy, includingPropertiesForKeys: nil)) ?? []
        for source in contents where source.pathExtension == "json" {
            let target = destination.appendingPathComponent(source.lastPathComponent)
            guard !fileManager.fileExists(atPath: target.path) else { continue }
            do {
                try fileManager.copyItem(at: source, to: target)
                Log.persistence.log("Migrated legacy HerdMan file \(source.lastPathComponent, privacy: .public)")
            } catch {
                Log.persistence.error("Failed to migrate legacy HerdMan file \(source.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)")
            }
        }
    }

    /// Canonical server-state layout shared with standalone installs: the
    /// server's database and logs live at ~/.codevisor/{data,logs} on every OS
    /// so machine state is laid out identically everywhere (a prerequisite for
    /// moving sessions between machines). Development builds keep their
    /// isolated per-instance directories under Application Support instead.
    public static func serverDataDirectoryURL(fileManager: FileManager = .default) -> URL {
        guard !isDevelopment else { return applicationSupportURL(fileManager: fileManager) }
        return createdDirectory(
            at: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codevisor/data", isDirectory: true),
            fileManager: fileManager
        )
    }

    public static func serverLogsDirectoryURL(fileManager: FileManager = .default) -> URL {
        guard !isDevelopment else { return applicationSupportURL(fileManager: fileManager) }
        return createdDirectory(
            at: fileManager.homeDirectoryForCurrentUser
                .appendingPathComponent(".codevisor/logs", isDirectory: true),
            fileManager: fileManager
        )
    }

    private static func createdDirectory(at directory: URL, fileManager: FileManager) -> URL {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.persistence.error("Failed to create data directory \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return directory
    }
}
