import AppKit
import Foundation
import HerdManCore
import os

/// Installs a downloaded release over the running app: extracts the archive,
/// verifies the new bundle, stops the local server (so the relaunched app boots
/// the updated bundled runtime), swaps the app bundle in place, and relaunches.
@MainActor
struct AppUpdateInstaller {
    let environment: AppEnvironment

    enum InstallError: LocalizedError {
        case missingArchive
        case appBundleMissing
        case signatureInvalid
        case extractionFailed
        case relaunchFailed

        var errorDescription: String? {
            switch self {
            case .missingArchive:
                return "This release has no downloadable app archive."
            case .appBundleMissing:
                return "The downloaded archive didn't contain HerdMan.app."
            case .signatureInvalid:
                return "The downloaded app failed code signature verification."
            case .extractionFailed:
                return "The downloaded archive couldn't be extracted."
            case .relaunchFailed:
                return "The update was installed, but HerdMan couldn't relaunch itself. Quit and reopen HerdMan to finish."
            }
        }
    }

    func install(_ release: AppUpdateRelease) async throws {
        guard let archiveURL = release.archiveURL else {
            // No archive asset: fall back to the release page so the user can
            // update manually (e.g. brew upgrade).
            if let page = release.releasePageURL {
                NSWorkspace.shared.open(page)
            }
            throw InstallError.missingArchive
        }

        let staging = FileManager.default.temporaryDirectory
            .appendingPathComponent("HerdManUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let (downloaded, _) = try await URLSession.shared.download(from: archiveURL)
        let archive = staging.appendingPathComponent("HerdMan-macOS.zip")
        try FileManager.default.moveItem(at: downloaded, to: archive)

        // ditto preserves code signatures and extended attributes.
        try await runChecked("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path], onFailure: .extractionFailed)

        let newApp = try locateAppBundle(in: staging)
        try await verifyCodeSignature(of: newApp)

        // Stop the local server before the swap so the next launch starts the
        // updated bundled runtime instead of reconnecting to the old one.
        await environment.localServer?.shutdown()

        let bundleURL = Bundle.main.bundleURL
        let backup = staging.appendingPathComponent("HerdMan-previous.app")
        try FileManager.default.moveItem(at: bundleURL, to: backup)
        do {
            try FileManager.default.moveItem(at: newApp, to: bundleURL)
        } catch {
            // Put the old app back so the user isn't left without one.
            do {
                try FileManager.default.moveItem(at: backup, to: bundleURL)
            } catch let rollbackError {
                Log.updates.error("update rollback failed, app bundle missing from \(bundleURL.path, privacy: .public): \(String(describing: rollbackError), privacy: .public)")
            }
            throw error
        }

        try relaunch(bundleURL: bundleURL)
    }

    private func locateAppBundle(in directory: URL) throws -> URL {
        let contents = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        )
        guard let app = contents.first(where: { $0.pathExtension == "app" }),
              let bundle = Bundle(url: app),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier
        else {
            throw InstallError.appBundleMissing
        }
        return app
    }

    private func verifyCodeSignature(of app: URL) async throws {
        try await runChecked(
            "/usr/bin/codesign",
            ["--verify", "--deep", "--strict", app.path],
            onFailure: .signatureInvalid
        )
    }

    /// Relaunches the (now replaced) app bundle and terminates this process.
    /// The helper shell outlives us, waits for the process to exit, and opens
    /// the new bundle with a fresh instance.
    private func relaunch(bundleURL: URL) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"\(bundleURL.path)\""]
        do {
            try helper.run()
        } catch {
            // The swap already happened; quitting now would strand the user
            // with no running app and no explanation. Surface it instead.
            Log.updates.fault("update relaunch helper failed to launch: \(String(describing: error), privacy: .public)")
            throw InstallError.relaunchFailed
        }
        NSApp.terminate(nil)
    }

    private func runChecked(
        _ executable: String,
        _ arguments: [String],
        onFailure failure: InstallError
    ) async throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        let status: Int32 = try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do {
                try process.run()
            } catch {
                process.terminationHandler = nil
                continuation.resume(throwing: error)
            }
        }
        guard status == 0 else { throw failure }
    }
}
