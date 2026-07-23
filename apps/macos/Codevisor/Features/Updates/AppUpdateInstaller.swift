import AppKit
import Foundation
import CodevisorCore
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
        case destinationExists
        case serverDidNotStop
        case relaunchFailed

        var errorDescription: String? {
            switch self {
            case .missingArchive:
                return "This release has no downloadable app archive."
            case .appBundleMissing:
                return "The downloaded archive didn't contain Codevisor.app."
            case .signatureInvalid:
                return "The downloaded app failed code signature verification."
            case .extractionFailed:
                return "The downloaded archive couldn't be extracted."
            case .destinationExists:
                return "Codevisor.app already exists next to this app. Remove the duplicate and try the update again."
            case .serverDidNotStop:
                return "The existing Codevisor server could not be stopped safely. The update was not installed."
            case .relaunchFailed:
                return "Codevisor couldn't start the update helper. The update was not installed."
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
            .appendingPathComponent("CodevisorUpdate-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)

        let (downloaded, _) = try await URLSession.shared.download(from: archiveURL)
        let archive = staging.appendingPathComponent("Codevisor-macOS.zip")
        try FileManager.default.moveItem(at: downloaded, to: archive)

        // ditto preserves code signatures and extended attributes.
        try await runChecked("/usr/bin/ditto", ["-x", "-k", archive.path, staging.path], onFailure: .extractionFailed)

        let newApp = try locateAppBundle(in: staging)
        try await verifyCodeSignature(of: newApp)

        // Stop the local server before the swap so the next launch starts the
        // updated bundled runtime instead of reconnecting to the old one.
        if let localServer = environment.localServer,
           !(await localServer.shutdown()) {
            throw InstallError.serverDidNotStop
        }

        let originalBundleURL = Bundle.main.bundleURL
        // The first branded update may be running from HerdMan.app. Install
        // the new bundle at its canonical filename so Finder, Dock, Spotlight,
        // Homebrew, and subsequent in-app updates all agree on Codevisor.app.
        let bundleURL = originalBundleURL
            .deletingLastPathComponent()
            .appendingPathComponent("Codevisor.app", isDirectory: true)
        if bundleURL != originalBundleURL,
           FileManager.default.fileExists(atPath: bundleURL.path) {
            throw InstallError.destinationExists
        }
        try installAfterExit(
            originalBundleURL: originalBundleURL,
            bundleURL: bundleURL,
            newAppURL: newApp,
            stagingURL: staging,
            expectedVersion: release.version
        )
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

    /// Commits the bundle swap only after this process exits. Moving a live
    /// `.app` changes the path macOS uses for attribution and was the source of
    /// stale `Codevisor-previous.app` Accessibility entries. The helper owns
    /// the transaction: swap, launch, verify the exact replacement runtime,
    /// then delete the backup. Any failure restores and reopens the old app.
    private func installAfterExit(
        originalBundleURL: URL,
        bundleURL: URL,
        newAppURL: URL,
        stagingURL: URL,
        expectedVersion: String
    ) throws {
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            """
            owner_pid="$1"
            old_bundle_path="$2"
            bundle_path="$3"
            new_bundle_path="$4"
            staging_path="$5"
            health_url="$6"
            expected_version="$7"
            backup_path="$staging_path/Codevisor-previous.app"
            failed_path="$staging_path/Codevisor-failed.app"
            log_path="$HOME/Library/Logs/Codevisor/update.log"
            /bin/mkdir -p "$(/usr/bin/dirname "$log_path")"
            exec >>"$log_path" 2>&1

            rollback() {
              # Stop only the replacement app and its app-owned server before
              # putting the previous bundle back at its original path.
              replacement_pid=$(
                /bin/ps -axo pid=,command= \
                  | /usr/bin/grep -F "$bundle_path/Contents/MacOS/" \
                  | /usr/bin/grep -v grep \
                  | /usr/bin/awk 'NR == 1 { print $1 }'
              )
              if [ -n "$replacement_pid" ]; then
                /bin/kill -TERM "$replacement_pid" 2>/dev/null || true
                wait_attempts=0
                while /bin/kill -0 "$replacement_pid" 2>/dev/null \
                  && [ "$wait_attempts" -lt 50 ]; do
                  wait_attempts=$((wait_attempts + 1))
                  /bin/sleep 0.1
                done
                /bin/kill -KILL "$replacement_pid" 2>/dev/null || true
              fi
              /usr/bin/curl -fsS --max-time 1 -X POST \
                "${health_url%/health}/shutdown" >/dev/null 2>&1 || true
              wait_attempts=0
              while /usr/bin/curl -fsS --max-time 1 "$health_url" >/dev/null 2>&1 \
                && [ "$wait_attempts" -lt 50 ]; do
                wait_attempts=$((wait_attempts + 1))
                /bin/sleep 0.1
              done
              if [ -e "$bundle_path" ]; then
                /bin/mv "$bundle_path" "$failed_path" || return 1
              fi
              /bin/mv "$backup_path" "$old_bundle_path" || return 1
              /usr/bin/open -n "$old_bundle_path" || return 1
            }

            while /bin/kill -0 "$owner_pid" 2>/dev/null; do /bin/sleep 0.1; done

            if ! /bin/mv "$old_bundle_path" "$backup_path"; then
              /usr/bin/open -n "$old_bundle_path" || true
              exit 1
            fi
            if ! /bin/mv "$new_bundle_path" "$bundle_path"; then
              /bin/mv "$backup_path" "$old_bundle_path" || true
              /usr/bin/open -n "$old_bundle_path" || true
              exit 1
            fi
            if ! /usr/bin/open -n "$bundle_path"; then
              rollback
              exit 1
            fi

            attempts=0
            while [ "$attempts" -lt 9000 ]; do
              health=$(/usr/bin/curl -fsS --max-time 1 "$health_url" 2>/dev/null || true)
              if /usr/bin/printf '%s' "$health" | /usr/bin/grep -Fq '"database":"ready"' \
                && /usr/bin/printf '%s' "$health" | /usr/bin/grep -Fq '"appOwned":true' \
                && /usr/bin/printf '%s' "$health" \
                  | /usr/bin/grep -Fq "\\"version\\":\\"$expected_version\\""; then
                /bin/rm -rf "$staging_path"
                exit 0
              fi
              attempts=$((attempts + 1))
              /bin/sleep 0.1
            done

            rollback
            exit 1
            """,
            "codevisor-update-relauncher",
            String(ProcessInfo.processInfo.processIdentifier),
            originalBundleURL.path,
            bundleURL.path,
            newAppURL.path,
            stagingURL.path,
            "http://127.0.0.1:\(CodevisorServerConfig.localPort)/v1/health",
            expectedVersion
        ]
        do {
            try helper.run()
        } catch {
            // No filesystem mutation has happened yet, so keeping this app
            // running is sufficient recovery.
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
