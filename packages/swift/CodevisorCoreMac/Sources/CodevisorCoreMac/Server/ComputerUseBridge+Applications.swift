import AppKit
import Foundation

struct ComputerUseApplicationIdentity: Equatable {
    let id: String
    let displayName: String
    let path: String
}

func computerUseApplicationIsProtected(_ identity: ComputerUseApplicationIdentity) -> Bool {
    let normalized = [identity.displayName, identity.id, identity.path]
        .joined(separator: " ")
        .lowercased()
        .replacingOccurrences(of: " ", with: "")
    let protected = [
        "1password", "com.agilebits", "bitwarden", "lastpass",
        "dashlane", "keeper", "keychainaccess", "com.apple.passwords",
    ]
    return protected.contains(where: normalized.contains)
}

/// Native Computer Use accepts a display name, bundle identifier, or full app
/// path. Keep that matching logic independent from NSWorkspace so installed
/// and running app resolution cannot drift apart.
func computerUseApplicationMatchScore(
    query: String,
    identity: ComputerUseApplicationIdentity
) -> Int? {
    let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    let expandedPath = (query as NSString).expandingTildeInPath.lowercased()
    let exactValues = [
        identity.id.lowercased(),
        identity.displayName.lowercased(),
        identity.path.lowercased(),
        URL(fileURLWithPath: identity.path).deletingPathExtension().lastPathComponent.lowercased(),
    ]
    if exactValues.contains(normalized) || exactValues.contains(expandedPath) { return 0 }
    return identity.displayName.lowercased().contains(normalized) ? 1 : nil
}

func computerUseApplicationSearchRoots(homeDirectory: URL) -> [URL] {
    [
        URL(fileURLWithPath: "/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Applications", isDirectory: true),
        URL(fileURLWithPath: "/System/Library/CoreServices/Applications", isDirectory: true),
        homeDirectory.appendingPathComponent("Applications", isDirectory: true),
    ]
}

extension ComputerUseBridge {
    private struct InstalledApplication {
        let identity: ComputerUseApplicationIdentity
        let url: URL
    }

    private final class ApplicationLaunchResult: @unchecked Sendable {
        private let lock = NSLock()
        private var application: NSRunningApplication?
        private var error: Error?

        func store(application: NSRunningApplication?, error: Error?) {
            lock.withLock {
                self.application = application
                self.error = error
            }
        }

        func load() -> (application: NSRunningApplication?, error: Error?) {
            lock.withLock { (application, error) }
        }
    }

    func listApps() throws -> [String: Any] {
        let running = controllableRunningApplications()
        var seen = Set<String>()
        var apps = installedApplications().map { application in
            seen.insert(application.identity.id.lowercased())
            return [
                "id": application.identity.id,
                "displayName": application.identity.displayName,
                "isRunning": running.contains(where: {
                    computerUseApplicationMatchScore(
                        query: application.identity.id,
                        identity: runningIdentity($0)
                    ) == 0
                }),
            ] as [String: Any]
        }
        // Include running apps outside the standard install roots (development
        // builds and apps launched from mounted volumes are common examples).
        for app in running {
            let identity = runningIdentity(app)
            guard seen.insert(identity.id.lowercased()).inserted else { continue }
            apps.append([
                "id": identity.id,
                "displayName": identity.displayName,
                "isRunning": true,
            ])
        }
        apps =
            apps
            .sorted {
                String(describing: $0["displayName"]).localizedCaseInsensitiveCompare(
                    String(describing: $1["displayName"])) == .orderedAscending
            }
        return textResult(try json(apps))
    }

    private func controllableRunningApplications() -> [NSRunningApplication] {
        NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated
                && $0.activationPolicy == .regular
        }
    }

    private func runningIdentity(_ app: NSRunningApplication) -> ComputerUseApplicationIdentity {
        let path = app.bundleURL?.path ?? app.executableURL?.path ?? ""
        let displayName =
            app.localizedName
            ?? app.bundleURL?.deletingPathExtension().lastPathComponent
            ?? app.bundleIdentifier
            ?? "App"
        return ComputerUseApplicationIdentity(
            id: app.bundleIdentifier ?? (path.isEmpty ? String(app.processIdentifier) : path),
            displayName: displayName,
            path: path
        )
    }

    private func installedApplication(at url: URL) -> InstalledApplication? {
        let standardized = url.standardizedFileURL
        guard standardized.pathExtension.lowercased() == "app",
            let bundle = Bundle(url: standardized)
        else { return nil }
        let info = bundle.infoDictionary ?? [:]
        guard info["LSBackgroundOnly"] as? Bool != true,
            info["LSUIElement"] as? Bool != true
        else { return nil }
        let displayName =
            (info["CFBundleDisplayName"] as? String)
            ?? (info[kCFBundleNameKey as String] as? String)
            ?? standardized.deletingPathExtension().lastPathComponent
        let identity = ComputerUseApplicationIdentity(
            id: bundle.bundleIdentifier ?? standardized.path,
            displayName: displayName,
            path: standardized.path
        )
        return InstalledApplication(identity: identity, url: standardized)
    }

    private func installedApplications() -> [InstalledApplication] {
        var urls = Set<URL>()
        for app in controllableRunningApplications() {
            if let url = app.bundleURL { urls.insert(url.standardizedFileURL) }
        }
        for root in computerUseApplicationSearchRoots(
            homeDirectory: FileManager.default.homeDirectoryForCurrentUser
        ) where FileManager.default.fileExists(atPath: root.path) {
            guard
                let enumerator = FileManager.default.enumerator(
                    at: root,
                    includingPropertiesForKeys: nil,
                    options: [.skipsHiddenFiles, .skipsPackageDescendants]
                )
            else { continue }
            for case let url as URL in enumerator where url.pathExtension.lowercased() == "app" {
                urls.insert(url.standardizedFileURL)
                enumerator.skipDescendants()
            }
        }
        var byIdentity: [String: InstalledApplication] = [:]
        for application in urls.compactMap(installedApplication(at:)) {
            byIdentity[application.identity.id.lowercased()] = application
        }
        return byIdentity.values.sorted {
            $0.identity.displayName.localizedCaseInsensitiveCompare($1.identity.displayName)
                == .orderedAscending
        }
    }

    func resolveApp(_ query: String) throws -> NSRunningApplication {
        let normalized = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { throw BridgeError("app is required") }
        if let pid = pid_t(normalized),
            let exactPID = controllableRunningApplications().first(where: {
                $0.processIdentifier == pid
            })
        {
            return try requireUnprotected(exactPID)
        }

        let runningMatches = controllableRunningApplications().compactMap { app -> (NSRunningApplication, Int)? in
            computerUseApplicationMatchScore(query: normalized, identity: runningIdentity(app))
                .map { (app, $0) }
        }
        if let exact = runningMatches.first(where: { $0.1 == 0 })?.0 {
            return try requireUnprotected(exact)
        }
        let fuzzyRunning = runningMatches.filter { $0.1 == 1 }
        if fuzzyRunning.count == 1, let app = fuzzyRunning.first?.0 {
            return try requireUnprotected(app)
        }

        var candidates = installedApplications()
        let expandedPath = (normalized as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: expandedPath),
            let direct = installedApplication(at: URL(fileURLWithPath: expandedPath))
        {
            candidates.insert(direct, at: 0)
        }
        if let bundleURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: normalized),
            let direct = installedApplication(at: bundleURL)
        {
            candidates.insert(direct, at: 0)
        }
        let installedMatches = candidates.compactMap { application -> (InstalledApplication, Int)? in
            computerUseApplicationMatchScore(query: normalized, identity: application.identity)
                .map { (application, $0) }
        }
        let exactInstalled = installedMatches.filter { $0.1 == 0 }.map { $0.0 }
        let selected: InstalledApplication
        if let first = exactInstalled.first {
            selected = first
        } else {
            let fuzzyInstalled = installedMatches.filter { $0.1 == 1 }.map { $0.0 }
            guard fuzzyInstalled.count == 1, let first = fuzzyInstalled.first else {
                throw BridgeError(
                    fuzzyInstalled.isEmpty ? "App not found: \(query)" : "App name is ambiguous"
                )
            }
            selected = first
        }
        try requireUnprotected(selected.identity)
        return try launchApplication(selected)
    }

    private func launchApplication(_ application: InstalledApplication) throws -> NSRunningApplication {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.addsToRecentItems = true
        configuration.createsNewApplicationInstance = false
        let completed = DispatchSemaphore(value: 0)
        let result = ApplicationLaunchResult()
        NSWorkspace.shared.openApplication(at: application.url, configuration: configuration) {
            launched, error in
            result.store(application: launched, error: error)
            completed.signal()
        }
        let deadline = DispatchTime.now() + 10
        if completed.wait(timeout: deadline) == .timedOut {
            throw BridgeError("Timed out launching \(application.identity.displayName)")
        }
        let launchResult = result.load()
        if let openError = launchResult.error {
            throw BridgeError(
                "Unable to launch \(application.identity.displayName): \(openError.localizedDescription)"
            )
        }
        if let openedApplication = launchResult.application {
            return try requireUnprotected(openedApplication)
        }
        for _ in 0..<50 {
            if let running = controllableRunningApplications().first(where: {
                computerUseApplicationMatchScore(
                    query: application.identity.id,
                    identity: runningIdentity($0)
                ) == 0
            }) {
                return try requireUnprotected(running)
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        throw BridgeError("\(application.identity.displayName) launched without a running app")
    }

    private func requireUnprotected(_ identity: ComputerUseApplicationIdentity) throws {
        if computerUseApplicationIsProtected(identity) {
            throw BridgeError("That app is protected and cannot be controlled by Computer Use")
        }
    }

    private func requireUnprotected(_ app: NSRunningApplication) throws -> NSRunningApplication {
        try requireUnprotected(runningIdentity(app))
        return app
    }
}
