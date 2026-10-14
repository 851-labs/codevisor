import AppKit
import CodevisorCore
import CodevisorCoreMac
import os

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  var settings: AppSettingsModel?
  var appUpdate: AppUpdateModel?

  private(set) var appInstanceLease: AppInstanceLease?

  private var skipsNextConfirmation = false

  private(set) static weak var current: AppDelegate?

  override init() {
    super.init()
    Self.current = self
  }

  func applicationDidFinishLaunching(_ notification: Notification) {
    guard appInstanceLease != nil else { return }
    Task { @MainActor in await AppRuntime.shared.startIfNeeded() }
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    let bundleURL = Bundle.main.bundleURL
    do {
      if let lease = try AppInstanceLease.acquireDefault(for: bundleURL) {
        appInstanceLease = lease
        return
      }

      if activateExistingInstance(from: bundleURL) {
        Log.updates.log("launch: another instance owns this bundle; activating it")
        NSApp.terminate(nil)
        return
      }
      if let lease = try AppInstanceLease.acquireDefault(for: bundleURL, waitFor: 5) {
        appInstanceLease = lease
        return
      }

      Log.updates.fault("launch: instance lease remained locked without a visible owner")
      _ = activateExistingInstance(from: bundleURL)
      NSApp.terminate(nil)
    } catch {
      Log.updates.fault("launch: could not acquire the app instance lease: \(error)")
      NSApp.terminate(nil)
    }
  }

  private func activateExistingInstance(from bundleURL: URL) -> Bool {
    guard let bundleIdentifier = Bundle.main.bundleIdentifier else { return false }
    let ownPID = ProcessInfo.processInfo.processIdentifier
    let ownBundle = bundleURL.resolvingSymlinksInPath().standardizedFileURL
    guard
      let existing = NSRunningApplication.runningApplications(
        withBundleIdentifier: bundleIdentifier
      ).first(where: {
        $0.processIdentifier != ownPID
          && $0.bundleURL?.resolvingSymlinksInPath().standardizedFileURL == ownBundle
      })
    else { return false }
    _ = existing.activate(options: [.activateAllWindows])
    return true
  }

  func terminateWithoutConfirmation() {
    skipsNextConfirmation = true
    NSApp.terminate(nil)
  }

  private var pendingQuitWindow: NSWindow?
  private var chromiumShutdownComplete = false
  private var chromiumShutdownInProgress = false

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    if chromiumShutdownComplete { return .terminateNow }
    if chromiumShutdownInProgress { return .terminateCancel }
    let skip = skipsNextConfirmation
    skipsNextConfirmation = false
    guard !skip, let settings, settings.shouldConfirmBeforeQuitting else { return terminateBrowsers(sender) }
    if appUpdate?.isUpdating == true { return terminateBrowsers(sender) }
    if let pendingQuitWindow {
      pendingQuitWindow.makeKeyAndOrderFront(nil)
      return .terminateCancel
    }
    let alert = Self.makeQuitAlert()
    NSApp.activate()
    guard let window = Self.quitAlertHost() else {
      return Self.recordQuit(alert, response: alert.runModal(), settings: settings)
        ? terminateBrowsers(sender) : .terminateCancel
    }
    pendingQuitWindow = window
    window.makeKeyAndOrderFront(nil)
    alert.beginSheetModal(for: window) { [weak self] response in
      self?.pendingQuitWindow = nil
      let quit = Self.recordQuit(alert, response: response, settings: settings)
      NSApp.reply(toApplicationShouldTerminate: false)
      if quit {
        _ = self?.terminateBrowsers(NSApp)
      }
    }
    return .terminateLater
  }

  private func terminateBrowsers(_ sender: NSApplication) -> NSApplication.TerminateReply {
    chromiumShutdownInProgress = true
    DispatchQueue.main.async {
      CVShutdownChromium {
        self.chromiumShutdownComplete = true
        sender.terminate(nil)
      }
    }
    return .terminateCancel
  }

  private static func quitAlertHost() -> NSWindow? {
    let candidates = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 } + NSApp.orderedWindows
    return candidates.first { window in
      window.isVisible && !window.isMiniaturized && window.styleMask.contains(.titled)
        && !(window is NSPanel)
    }
  }

  private static func makeQuitAlert() -> NSAlert {
    let alert = NSAlert()
    alert.messageText = "Are you sure you want to quit?"
    alert.alertStyle = .warning
    alert.showsSuppressionButton = true
    alert.suppressionButton?.title = "Do not ask me again"
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    return alert
  }

  private static func recordQuit(
    _ alert: NSAlert,
    response: NSApplication.ModalResponse,
    settings: AppSettingsModel
  ) -> Bool {
    guard response == .alertFirstButtonReturn else { return false }
    if alert.suppressionButton?.state == .on {
      settings.setConfirmBeforeQuitting(false)
    }
    return true
  }
}
