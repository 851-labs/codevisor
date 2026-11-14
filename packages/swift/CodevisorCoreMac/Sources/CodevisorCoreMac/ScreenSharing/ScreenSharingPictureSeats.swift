import Foundation

struct ScreenSharingPictureSeats: Equatable {
  struct Seat: Equatable {
    let id: UUID
    let role: ScreenSharingViewerRole
    var isOnScreen = false
    var claimed = 0
  }

  private(set) var seats: [Seat] = []
  private(set) var holder: UUID?
  private var claims = 0

  var playsSound: Bool {
    seats.contains { $0.role != .watcher && $0.isOnScreen }
  }

  mutating func join(_ id: UUID, role: ScreenSharingViewerRole) {
    seats.append(Seat(id: id, role: role))
    if canTakeOver(id) { claim(id) }
  }

  mutating func leave(_ id: UUID) {
    seats.removeAll { $0.id == id }
    guard holder == id else { return }

    holder = successor(onScreenOnly: false)
  }

  mutating func setOnScreen(_ onScreen: Bool, for id: UUID) {
    guard let index = seats.firstIndex(where: { $0.id == id }) else { return }

    seats[index].isOnScreen = onScreen
    if onScreen {
      if canTakeOver(id) { claim(id) }
    } else if holder == id, let next = successor(onScreenOnly: true) {
      holder = next
    }
  }

  mutating func claim(_ id: UUID) {
    guard let index = seats.firstIndex(where: { $0.id == id }), seats[index].role != .watcher else { return }

    claims += 1
    seats[index].claimed = claims
    holder = id
  }

  private func occupant(_ id: UUID?) -> Seat? {
    seats.first { $0.id == id }
  }

  private func canTakeOver(_ id: UUID) -> Bool {
    guard let seat = occupant(id), seat.role != .watcher else { return false }
    guard let current = occupant(holder) else { return true }

    return seat.isOnScreen && (!current.isOnScreen || seat.role >= current.role)
  }

  private func successor(onScreenOnly: Bool) -> UUID? {
    let others = seats.filter { $0.id != holder && $0.role != .watcher }
    let onScreen = others.filter(\.isOnScreen)
    let candidates = onScreen.isEmpty && !onScreenOnly ? others : onScreen
    return candidates.max { ($0.role, $0.claimed) < ($1.role, $1.claimed) }?.id
  }
}
