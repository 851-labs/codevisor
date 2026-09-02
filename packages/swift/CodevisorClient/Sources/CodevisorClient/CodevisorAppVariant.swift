import Foundation

public enum CodevisorAppVariant: Sendable {
    public static let productionPort = 49_361
    public static let developmentPort = 49_362

    /// The URL scheme this build registered (Info.plist CFBundleURLTypes).
    /// Per-worktree dev builds suffix the scheme with their instance hash, so
    /// anything that generates a deeplink back to *this* app must use the
    /// registered value verbatim rather than assuming `codevisor-dev`.
    public static var registeredURLScheme: String? {
        (Bundle.main.infoDictionary?["CFBundleURLTypes"] as? [[String: Any]])?
            .compactMap { ($0["CFBundleURLSchemes"] as? [String])?.first }
            .first
    }

    private static let stashedEnvironmentKey = "dev.launchEnvironment"

    /// A development instance is configured entirely through CODEVISOR_*
    /// launch environment from `bun run dev`. Relaunches that bypass the
    /// runner — macOS's own "Quit & Reopen" after a Screen Recording grant,
    /// the Dock, Finder — start with none of it, which would silently point
    /// the app at a different instance's data. Stash the configuration under
    /// this bundle id (dev bundle ids are per-worktree, so per-instance) on
    /// every configured launch, and restore it on bare ones.
    private static let resolvedEnvironment: [String: String] = {
        let live = ProcessInfo.processInfo.environment
        guard isDevelopment else { return live }
        let resolution = resolvedDevelopmentEnvironment(
            live: live,
            stashed: UserDefaults.standard.dictionary(forKey: stashedEnvironmentKey)
                as? [String: String]
        )
        if let stash = resolution.stash {
            UserDefaults.standard.set(stash, forKey: stashedEnvironmentKey)
        }
        return resolution.environment
    }()

    /// Pure resolution: a configured launch wins and refreshes the stash; a
    /// bare launch inherits the stashed configuration; anything the live
    /// environment does define keeps precedence.
    static func resolvedDevelopmentEnvironment(
        live: [String: String],
        stashed: [String: String]?
    ) -> (environment: [String: String], stash: [String: String]?) {
        let devPrefixes = ["CODEVISOR_", "HERDMAN_"]
        let isConfigured =
            live["CODEVISOR_DEV_INSTANCE_ID"] != nil
            || live["HERDMAN_DEV_INSTANCE_ID"] != nil
        if isConfigured {
            let stash = live.filter { pair in
                devPrefixes.contains { pair.key.hasPrefix($0) }
            }
            return (live, stash)
        }
        guard let stashed, !stashed.isEmpty else { return (live, nil) }
        return (live.merging(stashed) { liveValue, _ in liveValue }, nil)
    }

    private static var environment: [String: String] {
        resolvedEnvironment
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

    /// Opts a development build into Sparkle using an isolated test feed.
    /// Production builds always use their normal architecture-specific feed.
    public static var developmentSparkleFeedURL: String? {
        guard isDevelopment,
            let value = environment["CODEVISOR_DEV_SPARKLE_FEED_URL"],
            !value.isEmpty
        else { return nil }
        return value
    }

    public static var enablesSparkleUpdater: Bool {
        !isDevelopment || developmentSparkleFeedURL != nil
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

        /// A dev-scheme deeplink that adds this machine, for testing the
        /// deeplink flow by opening it. Uses the scheme this build actually
        /// registered (per-worktree dev instances suffix it), falling back to
        /// the plain dev scheme.
        public var deeplink: String {
            var components = URLComponents()
            components.scheme = CodevisorAppVariant.registeredURLScheme ?? "codevisor-dev"
            components.host = "add-machine"
            components.queryItems = [
                URLQueryItem(name: "host", value: host),
                URLQueryItem(name: "port", value: String(port)),
                URLQueryItem(name: "token", value: token),
                URLQueryItem(name: "name", value: name),
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

    /// The cloud dev instance `bun run dev` starts alongside the app, so the
    /// account flows can be developed against a local Worker. Present only in
    /// development runs where the dev script provided its details.
    public struct DevelopmentCloud: Sendable, Equatable {
        /// The local cloud instance `bun run dev` runs. Apps sign into it the
        /// production way; no session ever rides the environment.
        public let url: URL

        public init(url: URL) {
            self.url = url
        }
    }

    public static var developmentCloud: DevelopmentCloud? {
        guard isDevelopment else { return nil }
        return developmentCloud(from: environment)
    }

    /// Pure parsing, split out for tests: an empty URL means no dev cloud.
    static func developmentCloud(from environment: [String: String]) -> DevelopmentCloud? {
        guard let raw = environment["CODEVISOR_DEV_CLOUD_URL"], !raw.isEmpty,
            let url = URL(string: raw)
        else { return nil }
        return DevelopmentCloud(url: url)
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
            !override.isEmpty
        {
            return createdDirectory(
                at: URL(fileURLWithPath: override, isDirectory: true),
                fileManager: fileManager
            )
        }
        let base =
            fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? Self.homeDirectory(fileManager: fileManager).appendingPathComponent("Library/Application Support")
        return createdDirectory(
            at: base.appendingPathComponent(applicationSupportDirectoryName, isDirectory: true),
            fileManager: fileManager
        )
    }

    public static func cacheURL(fileManager: FileManager = .default) -> URL {
        if isDevelopment,
            let override = environment["CODEVISOR_DEV_CACHE_DIR"],
            !override.isEmpty
        {
            return createdDirectory(
                at: URL(fileURLWithPath: override, isDirectory: true),
                fileManager: fileManager
            )
        }
        let base =
            fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
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
        guard let legacy = legacyApplicationSupportURL(fileManager: fileManager) else { return }
        migrateLegacyApplicationSupport(
            from: legacy,
            to: applicationSupportURL(fileManager: fileManager),
            fileManager: fileManager
        )
    }

    /// Pre-rename client data location. The SQLite bootstrap imports this
    /// directory directly and then removes its supported legacy artifacts
    /// after validation, rather than leaving a second authoritative copy.
    public static func legacyApplicationSupportURL(
        fileManager: FileManager = .default
    ) -> URL? {
        guard !isDevelopment else { return nil }
        let base =
            fileManager.urls(
                for: .applicationSupportDirectory,
                in: .userDomainMask
            ).first
            ?? Self.homeDirectory(fileManager: fileManager)
            .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("HerdMan", isDirectory: true)
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
                Log.persistence.error(
                    "Failed to migrate legacy HerdMan file \(source.lastPathComponent, privacy: .public): \(String(describing: error), privacy: .public)"
                )
            }
        }
    }

    /// Canonical server-state layout shared with standalone installs: the
    /// server's database and logs live at ~/.codevisor/{data,logs} on every OS
    /// so machine state is laid out identically everywhere (a prerequisite for
    /// moving sessions between machines). Development builds keep their
    /// isolated production-shaped directories supplied by the dev runner.
    public static func serverDataDirectoryURL(fileManager: FileManager = .default) -> URL {
        guard !isDevelopment else { return applicationSupportURL(fileManager: fileManager) }
        return createdDirectory(
            at: Self.homeDirectory(fileManager: fileManager)
                .appendingPathComponent(".codevisor/data", isDirectory: true),
            fileManager: fileManager
        )
    }

    public static func serverLogsDirectoryURL(fileManager: FileManager = .default) -> URL {
        if isDevelopment,
            let override = environment["CODEVISOR_DEV_LOGS_DIR"],
            !override.isEmpty
        {
            return createdDirectory(
                at: URL(fileURLWithPath: override, isDirectory: true),
                fileManager: fileManager
            )
        }
        guard !isDevelopment else { return applicationSupportURL(fileManager: fileManager) }
        return createdDirectory(
            at: Self.homeDirectory(fileManager: fileManager)
                .appendingPathComponent(".codevisor/logs", isDirectory: true),
            fileManager: fileManager
        )
    }

    /// `homeDirectoryForCurrentUser` is macOS-only; on iOS the sandbox home
    /// from `NSHomeDirectory()` is the equivalent (and these paths are only
    /// fallbacks/dev layouts there — iOS has no local server).
    private static func homeDirectory(fileManager: FileManager) -> URL {
        #if os(macOS)
            fileManager.homeDirectoryForCurrentUser
        #else
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        #endif
    }

    private static func createdDirectory(at directory: URL, fileManager: FileManager) -> URL {
        do {
            try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch {
            Log.persistence.error(
                "Failed to create data directory \(directory.path, privacy: .public): \(String(describing: error), privacy: .public)"
            )
        }
        return directory
    }
}
