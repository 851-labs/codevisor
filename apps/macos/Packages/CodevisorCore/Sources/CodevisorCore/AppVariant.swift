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
            let directory = URL(fileURLWithPath: override, isDirectory: true)
            do {
                try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            } catch {
                Log.persistence.error("Failed to create data directory \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
            }
            return directory
        }
        let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        let directory = base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true)
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.persistence.error("Failed to create data directory \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)")
        }
        return directory
    }
}
