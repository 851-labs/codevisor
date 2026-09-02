import AppKit
import CodevisorCore
import os

/// Relaunches Codevisor in place: a detached helper shell outlives this
/// process, waits for it to exit, and opens a fresh instance. Launching the
/// app restarts the managed local server too (`ensureRunning` on startup),
/// so this is the recovery action offered when the server is unreachable.
enum AppRelauncher {
    @MainActor
    static func relaunch() {
        let bundleURL = Bundle.main.bundleURL
        let helper = Process()
        helper.executableURL = URL(fileURLWithPath: "/bin/sh")
        // A development instance is configured entirely through CODEVISOR_*
        // launch environment (data directory, instance id, ports). `open`
        // starts a fresh process that would not inherit it, so the relaunched
        // app would read a different instance's state. Production has none of
        // these set, so this reduces to a plain reopen.
        let environmentArguments = ProcessInfo.processInfo.environment
            .filter { $0.key.hasPrefix("CODEVISOR_") }
            .sorted { $0.key < $1.key }
            .flatMap { ["--env", "\($0.key)=\($0.value)"] }
        helper.arguments =
            [
                "-c",
                """
                owner_pid="$1"
                bundle_path="$2"
                shift 2
                while /bin/kill -0 "$owner_pid" 2>/dev/null; do /bin/sleep 0.1; done
                exec /usr/bin/open -n "$@" "$bundle_path"
                """,
                "codevisor-relauncher",
                String(ProcessInfo.processInfo.processIdentifier),
                bundleURL.path,
            ] + environmentArguments
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
                    .appRelaunchFailed,
                    title: "Couldn't Restart Codevisor",
                    message: "Quit and reopen Codevisor manually."
                )
            }
            return
        }
        // The user just pressed Restart; asking "Are you sure you want to
        // quit?" now would be noise, and a Cancel would leave the helper
        // waiting to reopen an app that never exits.
        if let delegate = AppDelegate.current {
            delegate.terminateWithoutConfirmation()
        } else {
            NSApp.terminate(nil)
        }
    }
}
