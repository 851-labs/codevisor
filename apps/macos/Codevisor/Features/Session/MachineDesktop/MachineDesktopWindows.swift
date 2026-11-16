import AppKit
import CodevisorCore
import CodevisorCoreMac
import SwiftUI

@MainActor
final class MachineDesktopWindows {
  static let shared = MachineDesktopWindows()

  private static let initialSize = NSSize(width: 1100, height: 720)

  private var open: [String: (window: NSWindow, pane: ScreenSharingPane)] = [:]
  private var closeObservers: [String: NSObjectProtocol] = [:]

  func present(_ machine: CodevisorMachine, environment: AppEnvironment) {
    let shown = open[machine.id] ?? makeWindow(for: machine, environment: environment)
    open[machine.id] = shown
    shown.pane.openedByUser()
    shown.window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow(
    for machine: CodevisorMachine, environment: AppEnvironment
  ) -> (window: NSWindow, pane: ScreenSharingPane) {
    let pane = MachineDesktops.shared.pane(on: machine, role: .window)
    let host = NSHostingController(rootView: MachineDesktopDialog(pane: pane).environment(environment).themedRoot())
    host.sceneBridgingOptions = [.toolbars, .title]
    let window = NSWindow(contentViewController: host)
    window.title = "\(pane.machineName) – Desktop"
    window.styleMask.insert([.resizable, .miniaturizable])
    window.setContentSize(Self.initialSize)
    window.isReleasedWhenClosed = false
    window.center()
    let machineId = machine.id
    closeObservers[machineId] = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.closed(machineId) }
    }
    return (window, pane)
  }

  private func closed(_ machineId: String) {
    open.removeValue(forKey: machineId)?.pane.detach()
    closeObservers.removeValue(forKey: machineId).map(NotificationCenter.default.removeObserver)
  }
}
