import AppKit
import CodevisorCore
import SwiftUI

@MainActor
final class MachineDesktopWindows {
  static let shared = MachineDesktopWindows()

  private static let initialSize = NSSize(width: 1100, height: 720)

  private var windows: [String: NSWindow] = [:]
  private var closeObservers: [String: NSObjectProtocol] = [:]

  func present(_ session: MachineDesktopSession, machineId: String, environment: AppEnvironment) {
    let window = windows[machineId] ?? makeWindow(session, machineId: machineId, environment: environment)
    windows[machineId] = window
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow(
    _ session: MachineDesktopSession, machineId: String, environment: AppEnvironment
  ) -> NSWindow {
    let host = NSHostingController(
      rootView: MachineDesktopDialog(session: session).environment(environment).themedRoot())
    host.sceneBridgingOptions = [.toolbars, .title]
    let window = NSWindow(contentViewController: host)
    window.title = "\(session.window.machineName) – Desktop"
    window.styleMask.insert([.resizable, .miniaturizable])
    window.setContentSize(Self.initialSize)
    window.isReleasedWhenClosed = false
    window.center()
    closeObservers[machineId] = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.closed(machineId) }
    }
    return window
  }

  private func closed(_ machineId: String) {
    windows[machineId] = nil
    closeObservers.removeValue(forKey: machineId).map(NotificationCenter.default.removeObserver)
  }
}
