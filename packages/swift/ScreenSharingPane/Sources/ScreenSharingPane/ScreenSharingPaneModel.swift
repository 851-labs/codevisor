import CodevisorClient
import CodevisorCore
import CoreGraphics
import Foundation
import Observation
import ScreenSharing
import ScreenSharingConnection
import ScreenSharingV2

@MainActor
@Observable
public final class ScreenSharingPaneModel {
  public var keyboardShown = false
  public var connectionDetailsShown = false
  public private(set) var modifiers: ScreenSharingModifiers = []
  public let machineName: String

  private(set) var viewed: ScreenSharingViewedSession?

  @ObservationIgnored private let connection: ScreenSharingConnection
  @ObservationIgnored private let onDisplayChosen: (String) -> Void
  @ObservationIgnored private var surface: ScreenSharingSurface?
  @ObservationIgnored private var views: [UUID: Bool] = [:]
  @ObservationIgnored private var pointer = ScreenSharingPointerInput()

  public nonisolated static let requestedChroma = ScreenSharingV2Chroma.subsampled

  init(connection: ScreenSharingConnection, machineName: String, onDisplayChosen: @escaping (String) -> Void) {
    self.connection = connection
    self.machineName = machineName
    self.onDisplayChosen = onDisplayChosen
    watchSession()
  }

  public static func enableEngineV2(environment: AppEnvironment) {
    ScreenSharingMediaEndpoint.shared.configure { [weak environment] in
      await environment?.screenSharingEndpoint(requestingLocalNetwork: false)
    }
  }

  public var state: ScreenSharingConnectionState { connection.state }

  public var isViewing: Bool { connection.state == .live }

  public var stillConnectingStep: String? {
    guard connection.isTakingLong, case .connecting(let stage) = connection.state else { return nil }

    return stage.step(on: machineName)
  }

  var failure: ScreenSharingPaneFailure? {
    guard case .failed(let reason) = connection.state else { return nil }

    return ScreenSharingPaneFailure(reason: reason, machineName: machineName)
  }

  public var displays: [ServerScreenSharingDisplay] { connection.displays }

  public var selectedDisplay: ServerScreenSharingDisplay? { connection.display }

  public var control: ScreenSharingControlSession? { viewed?.control }

  public var diagnostics: ScreenSharingViewerDiagnostics? { viewed?.diagnostics }

  var session: (any ScreenSharingViewingSession)? { connection.session }

  public func openedByUser() {
    (surface ?? attach()).openedByUser()
  }

  public func retry() {
    surface?.retry()
  }

  public func viewHere() {
    surface?.viewHere()
  }

  public func reconnect() {
    connection.restart()
  }

  public func select(displayId id: String) {
    guard id != selectedDisplay?.id, displays.contains(where: { $0.id == id }) else { return }

    connection.switchDisplay(to: id)
    onDisplayChosen(id)
  }

  public func toggle(_ modifier: ScreenSharingModifiers) {
    modifiers.formSymmetricDifference(modifier)
  }

  public func type(_ text: String) {
    send(ScreenSharingKeyboard.type(text, modifiers: modifiers))
    modifiers = []
  }

  public func press(_ key: ScreenSharingKey) {
    send(ScreenSharingKeyboard.press(code: key.rawValue, modifiers: modifiers))
    modifiers = []
  }

  public func paste(_ text: String) {
    guard !text.isEmpty else { return }

    send(ScreenSharingKeyboard.type(text, modifiers: []))
  }

  func setOnScreen(_ onScreen: Bool, for view: UUID) {
    views[view] = onScreen
    viewsChanged()
  }

  func viewRemoved(_ view: UUID) {
    views[view] = nil
    viewsChanged()
  }

  func pressHardwareKey(usage: Int, modifiers flags: ScreenSharingModifiers) -> Bool {
    guard let code = ScreenSharingKeyboard.code(forHIDUsage: usage) else { return false }

    send(ScreenSharingKeyboard.press(code: code, modifiers: flags.union(modifiers)))
    modifiers = []
    return true
  }

  func tap(at pointer: ScreenSharingPointer, location: CGPoint, time: TimeInterval) {
    send(self.pointer.tap(at: pointer, location: location, time: time))
  }

  func secondaryClick(at pointer: ScreenSharingPointer) {
    send(self.pointer.secondaryClick(at: pointer))
  }

  func dragBegan(at pointer: ScreenSharingPointer) {
    send(self.pointer.dragBegan(at: pointer))
  }

  func dragMoved(to pointer: ScreenSharingPointer) {
    send(self.pointer.dragMoved(to: pointer))
  }

  func dragEnded(at pointer: ScreenSharingPointer) {
    send(self.pointer.dragEnded(at: pointer))
  }

  func scrolled(at pointer: ScreenSharingPointer, dx: Double, dy: Double) {
    send(self.pointer.scrolled(at: pointer, dx: dx, dy: dy))
  }

  private func send(_ events: [ScreenSharingInputEvent]) {
    guard isViewing, let control else { return }

    control.send(events)
  }

  private func attach() -> ScreenSharingSurface {
    let surface = connection.attach(.phone)
    self.surface = surface
    return surface
  }

  private func viewsChanged() {
    guard !views.isEmpty else { return allViewsClosed() }

    let onScreen = views.values.contains(true)
    if !onScreen { control?.release() }
    (surface ?? attach()).setOnScreen(onScreen)
  }

  private func allViewsClosed() {
    if keyboardShown { keyboardShown = false }
    control?.release()
    surface?.detach()
    surface = nil
  }

  private func watchSession() {
    let session = withObservationTracking {
      connection.session
    } onChange: { [weak self] in
      Task { @MainActor [weak self] in self?.watchSession() }
    }
    view(session)
  }

  private func view(_ session: (any ScreenSharingViewingSession)?) {
    guard viewed?.session !== session else { return }

    viewed?.close()
    pointer = ScreenSharingPointerInput()
    viewed = session.map { session in
      ScreenSharingViewedSession(session) { [weak self] in self?.isViewing == true }
    }
  }
}
