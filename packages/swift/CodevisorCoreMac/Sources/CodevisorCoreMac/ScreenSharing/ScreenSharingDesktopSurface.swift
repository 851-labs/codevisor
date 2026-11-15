import AppKit
import ComposableArchitecture
import Foundation
import OSLog
import ScreenSharingConnection

@MainActor
public final class ScreenSharingDesktopSurface {
  typealias FindDesktop = @MainActor () throws -> ScreenSharingDesktop?

  private static let logger = Logger(subsystem: "com.851labs.Codevisor", category: "ScreenSharing")

  public let role: ScreenSharingViewerRole
  public var onChange: ((ScreenSharingSurfaceSnapshot) -> Void)?
  public var onFocusChanged: ((Bool) -> Void)?
  public var onKeyboardReturned: (() -> Void)?
  public private(set) var snapshot = ScreenSharingSurfaceSnapshot()
  private let id = UUID()
  private let findDesktop: FindDesktop
  private let isMachineGone: @MainActor () -> Bool
  private let onShown: @MainActor () -> Void
  private var bound: (desktop: ScreenSharingDesktop, surface: ScreenSharingSurface)?
  private var bindFailure: String?
  private var isOnScreen = false
  private var seedDisplayId: String?
  private var isDetached = false
  private var observation: ObserveToken?

  init(
    role: ScreenSharingViewerRole, findDesktop: @escaping FindDesktop,
    isMachineGone: @escaping @MainActor () -> Bool, onShown: @escaping @MainActor () -> Void
  ) {
    self.role = role
    self.findDesktop = findDesktop
    self.isMachineGone = isMachineGone
    self.onShown = onShown
    watch()
  }

  isolated deinit {
    unbind()
  }

  public var videoHasKeyboardFocus: Bool { bound?.desktop.endpoint?.hasKeyboardFocus(in: id) ?? false }

  public func videoView() -> NSView? {
    bound?.desktop.endpoint?.view(for: id)
  }

  public func letterbox(_ color: NSColor) {
    bound?.desktop.endpoint?.letterbox(color, in: id)
  }

  public func setOnScreen(_ onScreen: Bool, seedDisplay displayId: String? = nil) {
    isOnScreen = onScreen
    seedDisplayId = displayId ?? seedDisplayId
    if onScreen {
      show()
    } else {
      hide()
    }
  }

  public func openedByUser() {
    Self.logger.notice("Desktop opened by the user in a \(String(describing: self.role), privacy: .public)")
    bound?.surface.openedByUser()
    bound?.desktop.openedByUser(id)
  }

  public func retry() {
    guard let bound else { return watch() }

    askForTheSavedDisplay(on: bound.desktop)
    bound.surface.retry()
  }

  public func takeControl() {
    bound?.desktop.takeControl(id)
  }

  public func setMode(_ mode: ScreenSharingViewer.InteractionMode) {
    bound?.desktop.setMode(mode, from: id)
  }

  public func controlForThisSession() {
    bound?.desktop.setMode(.control, from: id, remembered: false)
  }

  public func setDynamicResolution(_ enabled: Bool) {
    bound?.desktop.setDynamicResolution(enabled)
  }

  public func switchDisplay(to displayId: String) {
    bound?.desktop.selectDisplay(displayId)
  }

  public func detach() {
    isDetached = true
    observation = nil
    unbind()
    report()
  }

  private func watch() {
    guard !isDetached else { return }

    observation = observe { [weak self] in self?.refresh() }
  }

  private func refresh() {
    bindIfNeeded()
    report()
  }

  private func bindIfNeeded() {
    guard !isDetached, bound?.desktop.connection.isEnded != false else { return }

    unbind()
    do {
      guard let desktop = try findDesktop(), !desktop.connection.isEnded else { return }

      bindFailure = nil
      bound = (desktop, desktop.connection.attach(role.surfaceKind))
      desktop.join(id, role: role, events: events)
      if isOnScreen { show() }
    } catch {
      bindFailure = error.localizedDescription
    }
  }

  private var events: ScreenSharingDesktopSurfaceEvents {
    ScreenSharingDesktopSurfaceEvents(
      pictureChanged: { [weak self] in self?.report() },
      focusChanged: { [weak self] in self?.onFocusChanged?($0) },
      keyboardReturned: { [weak self] in self?.onKeyboardReturned?() })
  }

  private func unbind() {
    guard let bound else { return }

    self.bound = nil
    bound.surface.detach()
    bound.desktop.leave(id)
  }

  private func show() {
    guard let bound else { return }

    askForTheSavedDisplay(on: bound.desktop)
    bound.surface.setOnScreen(true)
    bound.desktop.setOnScreen(true, for: id)
    onShown()
  }

  private func askForTheSavedDisplay(on desktop: ScreenSharingDesktop) {
    guard startsOnRequest(desktop.connection.state) else { return }

    desktop.askForTheSavedDisplay(seed: seedDisplayId)
  }

  private func startsOnRequest(_ state: ScreenSharingConnectionState) -> Bool {
    switch state {
    case .off, .failed: true
    case .connecting, .live, .reconnecting: false
    }
  }

  private func hide() {
    bound?.surface.setOnScreen(false)
    bound?.desktop.setOnScreen(false, for: id)
  }

  private func report() {
    let current = currentSnapshot
    guard current != snapshot else { return }

    snapshot = current
    onChange?(current)
  }

  private var currentSnapshot: ScreenSharingSurfaceSnapshot {
    guard let desktop = bound?.desktop else { return unboundSnapshot }

    var snapshot = ScreenSharingSurfaceSnapshot()

    snapshot.connection = desktop.connection.state
    snapshot.isTakingLong = desktop.connection.isTakingLong
    snapshot.hostNotice = desktop.connection.hostNotice
    snapshot.displays = desktop.connection.displays
    snapshot.displayId = desktop.connection.display?.id
    snapshot.displaySwitch = desktop.connection.displaySwitch
    snapshot.switchesDisplayInSession = desktop.connection.switchesDisplayInSession
    snapshot.endpoint = desktop.endpoint
    snapshot.control = desktop.controller == id ? desktop.controlStatus : nil
    snapshot.mode = desktop.mode
    snapshot.dynamicResolution = desktop.dynamicResolution
    return snapshot
  }

  private var unboundSnapshot: ScreenSharingSurfaceSnapshot {
    var snapshot = ScreenSharingSurfaceSnapshot()
    if let bindFailure {
      snapshot.connection = .failed(.unclassified(message: bindFailure))
    } else if isMachineGone() {
      snapshot.connection = .failed(.cantReach)
    }
    return snapshot
  }
}
