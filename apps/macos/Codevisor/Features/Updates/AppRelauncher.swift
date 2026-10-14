import AppKit
import CodevisorCore
import os

enum AppRelauncher {
  @MainActor
  static func relaunch() {
    let bundleURL = Bundle.main.bundleURL
    let helper = Process()
    helper.executableURL = URL(fileURLWithPath: "/bin/sh")
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
        exec /usr/bin/open "$@" "$bundle_path"
        """,
        "codevisor-relauncher",
        String(ProcessInfo.processInfo.processIdentifier),
        bundleURL.path,
      ] + environmentArguments
    do {
      try helper.run()
    } catch {
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
    if let delegate = AppDelegate.current {
      delegate.terminateWithoutConfirmation()
    } else {
      NSApp.terminate(nil)
    }
  }
}
