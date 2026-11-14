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

  public let connection: ScreenSharingConnection
  public private(set) var endpoint: ScreenSharingViewerEndpoint?
  public private(set) var holder: UUID?
  @ObservationIgnored private var seats = ScreenSharingPictureSeats()
  @ObservationIgnored private var watchers: [UUID: @MainActor () -> Void] = [:]
  @ObservationIgnored private let makeEndpoint: MakeEndpoint
  @ObservationIgnored private var shownSession: ObjectIdentifier?
  @ObservationIgnored private var sessionObservation: ObserveToken?

  init(connection: ScreenSharingConnection, makeEndpoint: @escaping MakeEndpoint) {
    self.connection = connection
    self.makeEndpoint = makeEndpoint
    sessionObservation = observe { [weak self] in self?.show(connection.session) }
  }

  func join(_ id: UUID, role: ScreenSharingViewerRole, onPictureChanged: @escaping @MainActor () -> Void) {
    watchers[id] = onPictureChanged
    seat { $0.join(id, role: role) }
  }

  func leave(_ id: UUID) {
    watchers[id] = nil
    seat { $0.leave(id) }
  }

  func setOnScreen(_ onScreen: Bool, for id: UUID) {
    seat { $0.setOnScreen(onScreen, for: id) }
  }

  func claim(_ id: UUID) {
    seat { $0.claim(id) }
  }

  func close() {
    sessionObservation = nil
    show(nil)
  }

  private func seat(_ change: (inout ScreenSharingPictureSeats) -> Void) {
    let previous = seats.holder
    change(&seats)
    if let previous, previous != seats.holder { endpoint?.relinquish() }
    endpoint?.audio?.audible = seats.playsSound
    guard holder != seats.holder else { return }

    holder = seats.holder
    pictureChanged()
  }

  private func pictureChanged() {
    for watcher in watchers.values { watcher() }
  }

  private func show(_ session: (any ScreenSharingViewingSession)?) {
    let identity = session.map { ObjectIdentifier($0) }
    guard identity != shownSession else { return }

    shownSession = identity
    endpoint?.close()
    endpoint = session.flatMap { makeEndpoint($0, connection.display?.id) }
    endpoint?.audio?.audible = seats.playsSound
    pictureChanged()
  }
}
