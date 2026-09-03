import AppKit
import CodevisorCore
import CodevisorCoreMac
import os

/// AppKit lifecycle policy behind the SwiftUI `App`: establishes exclusive
/// ownership of this bundle before launch and confirms interactive ⌘Q because
/// quitting tears down every terminal and agent view at once.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Both are `nil` until client storage has opened; a quit before that
  /// has nothing to lose and is never questioned.
  var settings: AppSettingsModel?
  var appUpdate: AppUpdateModel?

  /// Held for this process's lifetime. Sparkle temporarily shares the same
  /// descriptor with a detached handoff helper while replacing the bundle.
  private(set) var appInstanceLease: AppInstanceLease?

  /// Set by flows that quit on the user's behalf after they already agreed
  /// to it (Restart Now, relaunch after a data reset). Consumed by the next
  /// termination request so a later ⌘Q asks again.
  private var skipsNextConfirmation = false

  static var current: AppDelegate? {
    NSApp.delegate as? AppDelegate
  }

  func applicationWillFinishLaunching(_ notification: Notification) {
    let bundleURL = Bundle.main.bundleURL
    do {
      if let lease = try AppInstanceLease.acquireDefault(for: bundleURL) {
        appInstanceLease = lease
        return
      }

      // A normal duplicate can leave immediately and focus its owner. During
      // Sparkle's swap the old process is already gone but the handoff helper
      // still owns the lock, so allow a short bounded wait for it to release.
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
      // Updating without the lease would recreate the crash window. Fail
      // closed and leave an actionable record instead of launching unsafely.
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

  /// Quits without the confirmation alert. For programmatic quits that
  /// follow an explicit user action, never for ⌘Q itself.
  func terminateWithoutConfirmation() {
    skipsNextConfirmation = true
    NSApp.terminate(nil)
  }

  /// The window whose sheet is currently asking; a second ⌘Q while it's
  /// up just brings that window forward instead of stacking alerts.
  private var pendingQuitWindow: NSWindow?

  func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
    let skip = skipsNextConfirmation
    skipsNextConfirmation = false
    guard !skip, let settings, settings.confirmBeforeQuitting else { return .terminateNow }
    // Sparkle quits the app itself to swap the bundle in; the user already
    // chose "Install and Relaunch", and a cancelled quit would leave the
    // installer waiting on this process forever.
    if appUpdate?.isUpdating == true { return .terminateNow }
    if let pendingQuitWindow {
      pendingQuitWindow.makeKeyAndOrderFront(nil)
      return .terminateCancel
    }
    let alert = Self.makeQuitAlert()
    // ⌘Q from the Dock menu or another app's Quit request can arrive
    // while Codevisor is in the background; the alert must be visible.
    NSApp.activate()
    // As a window sheet the alert dims and centers on the window, matching
    // the app's SwiftUI alerts. Without a usable window (all minimized, or
    // only Settings closed) fall back to the standalone app-modal panel.
    guard let window = Self.quitAlertHost() else {
      return Self.recordQuit(alert, response: alert.runModal(), settings: settings)
        ? .terminateNow : .terminateCancel
    }
    pendingQuitWindow = window
    window.makeKeyAndOrderFront(nil)
    alert.beginSheetModal(for: window) { [weak self] response in
      self?.pendingQuitWindow = nil
      let quit = Self.recordQuit(alert, response: response, settings: settings)
      NSApp.reply(toApplicationShouldTerminate: quit)
    }
    return .terminateLater
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
    // First button is the default (Return); "Cancel" also binds Escape.
    alert.addButton(withTitle: "Quit")
    alert.addButton(withTitle: "Cancel")
    return alert
  }

  /// Records "Do not ask me again" only when the user actually quits, so a
  /// ticked box on a cancelled alert doesn't silently disable the guard.
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
