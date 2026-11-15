import AppKit
import CodevisorClient
import CodevisorCore
import ComposableArchitecture
import Foundation
import Observation
import ScreenSharing
import ScreenSharingConnection

@MainActor
@Observable
public final class ScreenSharingDesktop {
  typealias MakeEndpoint =
    @MainActor (any ScreenSharingViewingSession, _ displayId: String?) -> ScreenSharingViewerEndpoint?

  private struct Seat {
    let role: ScreenSharingViewerRole
    let events: ScreenSharingDesktopSurfaceEvents
    var isOnScreen = false
    var wasOpenedByUser = false

    var canControl: Bool { role != .watcher }
  }

  public let connection: ScreenSharingConnection
  public private(set) var endpoint: ScreenSharingViewerEndpoint?
  public private(set) var dynamicResolution: Bool
  public var controller: UUID? { control.controller }
  public var controlStatus: ScreenSharingControlStatus { control.status }
  public var mode: ScreenSharingViewer.InteractionMode { control.mode }
  @ObservationIgnored private let control: ScreenSharingDesktopControl
  @ObservationIgnored private let preferences: ScreenSharingMachinePreferences
  @ObservationIgnored private var seats: [UUID: Seat] = [:]
  @ObservationIgnored private var chosenDisplayId: String?
  @ObservationIgnored private let makeEndpoint: MakeEndpoint
  @ObservationIgnored private var shownSession: ObjectIdentifier?
  @ObservationIgnored private var following: [ObserveToken] = []

  private var machineId: String { connection.machineId }

  init(
    connection: ScreenSharingConnection, preferences: ScreenSharingMachinePreferences = .init(),
    clock: any Clock<Duration> = ContinuousClock(), makeEndpoint: @escaping MakeEndpoint
  ) {
    self.connection = connection
    self.preferences = preferences
    self.makeEndpoint = makeEndpoint
    dynamicResolution = preferences.dynamicResolution(machineId: connection.machineId)
    let viewOnly = preferences.viewOnly(machineId: connection.machineId)
    control = ScreenSharingDesktopControl(mode: viewOnly ? .view : .control, clock: clock)
    following = [
      observe { [weak self] in self?.show(connection.session) },
      observe { [weak self] in self?.control.setLive(connection.state == .live) },
      observe { [weak self] in
        self?.saveTheChosenDisplay(preferred: connection.preferredDisplayId, shared: connection.display?.id)
        self?.configureResolution(for: connection.display?.id, among: connection.displays)
      },
    ]
  }

  func join(_ id: UUID, role: ScreenSharingViewerRole, events: ScreenSharingDesktopSurfaceEvents) {
    seats[id] = Seat(role: role, events: events)
  }

  func leave(_ id: UUID) {
    seats[id] = nil
    endpoint?.removeView(for: id)
    hidden(id)
  }

  func setOnScreen(_ onScreen: Bool, for id: UUID) {
    guard var seat = seats[id] else { return }

    seat.isOnScreen = onScreen
    let takesControl = onScreen && seat.wasOpenedByUser
    seat.wasOpenedByUser = false
    seats[id] = seat
    if onScreen {
      if takesControl { takeControlAndKeyboard(id) } else if seat.canControl { control.offer(id) }
      settle()
    } else {
      hidden(id)
    }
  }

  func openedByUser(_ id: UUID) {
    guard let seat = seats[id], seat.canControl else { return }
    guard seat.isOnScreen else {
      seats[id]?.wasOpenedByUser = true
      return
    }
    takeControlAndKeyboard(id)
    settle()
  }

  private func takeControlAndKeyboard(_ id: UUID) {
    control.take(id)
    if controller == id { endpoint?.focusView(for: id) }
  }

  func takeControl(_ id: UUID) {
    guard seats[id]?.canControl == true else { return }

    control.take(id)
    settle()
  }

  func setMode(_ mode: ScreenSharingViewer.InteractionMode, from id: UUID, remembered: Bool = true) {
    if remembered { preferences.setViewOnly(mode == .view, machineId: machineId) }
    control.setMode(mode, from: seats[id]?.canControl == true ? id : nil)
    settle()
  }

  func setDynamicResolution(_ enabled: Bool) {
    guard enabled != dynamicResolution else { return }

    dynamicResolution = enabled
    preferences.setDynamicResolution(enabled, machineId: machineId)
    endpoint?.setDynamicResolution(enabled)
    pictureChanged()
  }

  func selectDisplay(_ displayId: String) {
    chosenDisplayId = displayId
    connection.switchDisplay(to: displayId)
    saveTheChosenDisplay(preferred: connection.preferredDisplayId, shared: connection.display?.id)
  }

  func askForTheSavedDisplay(seed: String?) {
    guard let displayId = preferences.preferredDisplay(machineId: machineId) ?? seed else { return }

    connection.preferredDisplayId = displayId
  }

  func close() {
    following = []
    show(nil)
  }

  private func hidden(_ id: UUID) {
    if controller == id, let next = largestOnScreen() {
      control.take(next)
    } else {
      control.drop(id)
    }
    settle()
  }

  private func settle() {
    endpoint?.sizeDesktop(with: controller ?? largestOnScreen())
    endpoint?.audio?.audible = seats.values.contains { $0.canControl && $0.isOnScreen }
    pictureChanged()
  }

  private func largestOnScreen() -> UUID? {
    let shown = seats.filter { $0.value.canControl && $0.value.isOnScreen }
    return shown.keys.max { area(of: $0) < area(of: $1) }
  }

  private func area(of id: UUID) -> CGFloat {
    endpoint?.size(of: id).map { $0.width * $0.height } ?? 0
  }

  private func pictureChanged() {
    for seat in seats.values { seat.events.pictureChanged() }
  }

  private func saveTheChosenDisplay(preferred: String?, shared: String?) {
    guard let chosenDisplayId, chosenDisplayId == preferred || chosenDisplayId == shared else { return }

    preferences.setPreferredDisplay(chosenDisplayId, machineId: machineId)
    self.chosenDisplayId = nil
  }

  private func configureResolution(for displayId: String?, among displays: [ServerScreenSharingDisplay]) {
    guard let endpoint else { return }

    let display = displays.first { $0.id == displayId }
    if let width = display?.defaultWidth, let height = display?.defaultHeight {
      endpoint.defaultDesktopSize = (width, height)
    }
    endpoint.desktopCanScale = display?.scales?.contains(2) == true
    endpoint.setDynamicResolution(dynamicResolution)
  }

  private func show(_ session: (any ScreenSharingViewingSession)?) {
    let identity = session.map { ObjectIdentifier($0) }
    guard identity != shownSession else { return }

    shownSession = identity
    endpoint?.close()
    endpoint = session.flatMap { makeEndpoint($0, connection.display?.id) }
    endpoint?.onViewFocusChanged = { [weak self] id, focused in self?.seats[id]?.events.focusChanged(focused) }
    endpoint?.onViewKeyboardReturned = { [weak self] id in self?.seats[id]?.events.keyboardReturned() }
    endpoint?.onViewResized = { [weak self] _ in self?.resized() }
    configureResolution(for: connection.display?.id, among: connection.displays)
    control.attach(endpoint)
    if controller == nil, let next = largestOnScreen() { control.offer(next) }
    settle()
  }

  private func resized() {
    endpoint?.sizeDesktop(with: controller ?? largestOnScreen())
  }
}
