#if DEBUG
  import AppKit

  @MainActor
  enum ScreenshotOtherApps {
    private static var hidden: [NSRunningApplication] = []
    private static var interruptions: [DispatchSourceSignal] = []

    private static var restoreFile: String? {
      ProcessInfo.processInfo.environment["CODEVISOR_SCREENSHOT_HIDDEN_APPS_FILE"]
    }

    static func hide() {
      hidden = NSWorkspace.shared.runningApplications.filter {
        $0.activationPolicy == .regular && !$0.isHidden && $0 != NSRunningApplication.current
      }
      if let restoreFile {
        let pids = hidden.map { String($0.processIdentifier) }.joined(separator: "\n")
        try? pids.write(toFile: restoreFile, atomically: true, encoding: .utf8)
      }
      hidden.forEach { $0.hide() }
      interruptions = [SIGINT, SIGTERM].map { number in
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler {
          MainActor.assumeIsolated { restore() }
          exit(0)
        }
        source.resume()
        return source
      }
    }

    static func restore() {
      hidden.forEach { $0.unhide() }
      hidden = []
      if let restoreFile { try? FileManager.default.removeItem(atPath: restoreFile) }
    }
  }
#endif
