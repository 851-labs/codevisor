import AppKit
import CodevisorCore
import os

/// Relaunches Codevisor in place: a detached helper shell outlives this
/// process, waits for it to exit, and opens a fresh instance. Launching the
/// app restarts the managed local server too (`ensureRunning` on startup),
/// so this is the recovery action offered when the server is unreachable.
enum AppRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = [
            "-c",
            """
            owner_pid="$1"
            bundle_path="$2"
            while /bin/kill -0 "$owner_pid" 2>/dev/null; do /bin/sleep 0.1; done
            exec /usr/bin/open -n "$bundle_path"
            """,
            "codevisor-relauncher",
            String(ProcessInfo.processInfo.processIdentifier),
            bundleURL.path
        ]
        do {
            try helper.run()
        } catch {
            // Quitting without a relaunch helper would strand the user with
            // no app at all — stay running and say so instead.
            Log.updates.fault(
                "restart helper failed to launch: \(String(describing: error), privacy: .public)"
            )
            Task { @MainActor in
                ErrorReporter.shared.report(
                    "Couldn't Restart Codevisor",
                    message: "Quit and reopen Codevisor manually."
                )
            }
            return
        }
        NSApp.terminate(nil)
    }
}
