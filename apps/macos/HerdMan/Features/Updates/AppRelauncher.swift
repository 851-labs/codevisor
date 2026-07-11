import AppKit
import HerdManCore
import os

/// Relaunches HerdMan in place: a detached helper shell outlives this
/// process, waits for it to exit, and opens a fresh instance. Launching the
/// app restarts the managed local server too (`ensureRunning` on startup),
/// so this is the recovery action offered when the server is unreachable.
enum AppRelauncher {
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        helper.arguments = ["-c", "sleep 0.5; /usr/bin/open -n \"\(bundleURL.path)\""]
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
                    "Couldn't Restart HerdMan",
                    message: "Quit and reopen HerdMan manually."
                )
            }
            return
        }
        NSApp.terminate(nil)
    }
}
