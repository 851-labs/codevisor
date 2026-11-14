import ComposableArchitecture
import Foundation
import ScreenSharingConnection

@MainActor
public final class ScreenSharingDesktopSurface {
  typealias FindDesktop = @MainActor () throws -> ScreenSharingDesktop?

  public let role: ScreenSharingViewerRole
  public var onChange: ((ScreenSharingSurfaceSnapshot) -> Void)?
  public private(set) var snapshot = ScreenSharingSurfaceSnapshot()
  private let id = UUID()
  private let findDesktop: FindDesktop
  private let onShown: @MainActor () -> Void
  private var bound: (desktop: ScreenSharingDesktop, surface: ScreenSharingSurface)?
  private var bindFailure: String?
  private var isOnScreen = false
  private var preferredDisplayId: String?
  private var isDetached = false
  private var observation: ObserveToken?

  init(role: ScreenSharingViewerRole, findDesktop: @escaping FindDesktop, onShown: @escaping @MainActor () -> Void) {
    self.role = role
    self.findDesktop = findDesktop
    self.onShown = onShown
    watch()
  }

  isolated deinit {
    unbind()
  }

  public func setOnScreen(_ onScreen: Bool, preferringDisplay displayId: String?) {
    isOnScreen = onScreen
    preferredDisplayId = displayId
    if onScreen {
      show()
    } else {
      hide()
    }
  }

  public func openedByUser() {
    bound?.surface.openedByUser()
  }

  public func retry() {
    guard let bound else { return watch() }

    bound.surface.retry()
  }

  public func takePicture() {
    bound?.desktop.claim(id)
  }

  public func switchDisplay(to displayId: String) {
    bound?.desktop.connection.switchDisplay(to: displayId)
  }

  public func detach() {
    isDetached = true
    observation = nil
    unbind()
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
      desktop.join(id, role: role) { [weak self] in self?.report() }
      if isOnScreen { show() }
    } catch {
      bindFailure = error.localizedDescription
    }
  }

  private func unbind() {
    guard let bound else { return }

    self.bound = nil
    bound.surface.detach()
    bound.desktop.leave(id)
  }

  private func show() {
    guard let bound else { return }

    let connection = bound.desktop.connection
    if connection.state == .off, let preferredDisplayId { connection.preferredDisplayId = preferredDisplayId }
    bound.surface.setOnScreen(true)
    bound.desktop.setOnScreen(true, for: id)
    onShown()
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
    var snapshot = ScreenSharingSurfaceSnapshot()
    guard let desktop = bound?.desktop else {
      if let bindFailure { snapshot.connection = .failed(.unclassified(message: bindFailure)) }
      return snapshot
    }

    snapshot.connection = desktop.connection.state
    snapshot.isTakingLong = desktop.connection.isTakingLong
    snapshot.hostNotice = desktop.connection.hostNotice
    snapshot.displays = desktop.connection.displays
    snapshot.displayId = desktop.connection.display?.id
    snapshot.picture = picture(on: desktop)
    return snapshot
  }

  private func picture(on desktop: ScreenSharingDesktop) -> ScreenSharingSurfaceSnapshot.Picture {
    guard let endpoint = desktop.endpoint else { return .none }

    return desktop.holder == id ? .here(endpoint) : .elsewhere(endpoint)
  }
}
