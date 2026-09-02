import AppKit
import CodevisorCore

/// The AppKit delegate behind the SwiftUI `App`. Its one job today is the
/// ⌘Q confirmation: quitting tears down every terminal and agent view at
/// once, and ⌘Q sits next to ⌘W, so a quit request is confirmed first unless
/// the user opted out ("Do not ask me again", or Settings).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
  /// Both are `nil` until client storage has opened; a quit before that
  /// has nothing to lose and is never questioned.
  var settings: AppSettingsModel?
  var appUpdate: AppUpdateModel?

  /// Set by flows that quit on the user's behalf after they already agreed
  /// to it (Restart Now, relaunch after a data reset). Consumed by the next
  /// termination request so a later ⌘Q asks again.
  private var skipsNextConfirmation = false

  static var current: AppDelegate? {
    NSApp.delegate as? AppDelegate
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
