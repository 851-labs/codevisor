import AppKit
import CodevisorCore
import Observation
import SwiftUI

@MainActor
@Observable
final class MachineDesktopWindows {
  static let shared = MachineDesktopWindows()

  private static let initialSize = NSSize(width: 1100, height: 720)

  private(set) var openWorkspaceIds: Set<UUID> = []
  @ObservationIgnored private var windows: [UUID: NSWindow] = [:]
  @ObservationIgnored private var closeObservers: [UUID: NSObjectProtocol] = [:]

  func isOpen(_ workspaceId: UUID) -> Bool { openWorkspaceIds.contains(workspaceId) }

  func present(_ session: MachineDesktopSession, workspaceId: UUID, environment: AppEnvironment) {
    let window = windows[workspaceId] ?? makeWindow(session, workspaceId: workspaceId, environment: environment)
    windows[workspaceId] = window
    openWorkspaceIds.insert(workspaceId)
    window.makeKeyAndOrderFront(nil)
  }

  private func makeWindow(
    _ session: MachineDesktopSession, workspaceId: UUID, environment: AppEnvironment
  ) -> NSWindow {
    let host = NSHostingController(
      rootView: MachineDesktopDialog(session: session).environment(environment).themedRoot())
    host.sceneBridgingOptions = [.toolbars, .title]
    let window = NSWindow(contentViewController: host)
    window.title = "\(session.pane.machineName) – Desktop"
    window.styleMask.insert([.resizable, .miniaturizable])
    window.setContentSize(Self.initialSize)
    window.isReleasedWhenClosed = false
    window.center()
    closeObservers[workspaceId] = NotificationCenter.default.addObserver(
      forName: NSWindow.willCloseNotification, object: window, queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated { self?.closed(workspaceId) }
    }
    return window
  }

  private func closed(_ workspaceId: UUID) {
    openWorkspaceIds.remove(workspaceId)
    windows[workspaceId] = nil
    closeObservers.removeValue(forKey: workspaceId).map(NotificationCenter.default.removeObserver)
  }
}
