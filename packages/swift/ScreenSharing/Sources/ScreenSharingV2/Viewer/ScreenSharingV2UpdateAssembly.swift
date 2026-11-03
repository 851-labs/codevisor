import CoreVideo

struct ScreenSharingV2UpdateAssembly {
  struct Group {
    let update: ScreenSharingTileUpdate
    var waiting: Set<Int>
    var arrived: Set<Int> = []
    var decoded: [ScreenSharingV2DecodeContext] = []
    var images: [Int: CVPixelBuffer] = [:]
  }

  enum Outcome: @unchecked Sendable {
    case decoded(ScreenSharingV2DecodeContext, CVPixelBuffer)
    case missing
  }

  static let maximumPending = 8

  private var pending: [Group] = []
  private var newestReleased: UInt32?

  mutating func received(_ update: ScreenSharingTileUpdate, tile: Int) {
    guard !isReleased(update.id) else { return }

    for index in pending.indices where Self.precedes(pending[index].update.id, update.id) {
      if !pending[index].arrived.contains(tile) { pending[index].waiting.remove(tile) }
    }
    if let index = pending.firstIndex(where: { $0.update.id == update.id }) {
      pending[index].arrived.insert(tile)
      return
    }

    var group = Group(update: update, waiting: update.tiles)
    group.arrived.insert(tile)
    let position = pending.firstIndex { Self.precedes(update.id, $0.update.id) } ?? pending.endIndex
    pending.insert(group, at: position)
  }

  mutating func resolve(update id: UInt32, tile: Int, _ outcome: Outcome) -> Bool {
    guard let index = pending.firstIndex(where: { $0.update.id == id }) else { return false }

    pending[index].waiting.remove(tile)
    if case .decoded(let context, let image) = outcome {
      pending[index].decoded.append(context)
      pending[index].images[tile] = image
    }
    return true
  }

  mutating func skipped(tile: Int) {
    guard let index = pending.firstIndex(where: { $0.waiting.contains(tile) && !$0.arrived.contains(tile) }) else {
      return
    }

    pending[index].waiting.remove(tile)
  }

  mutating func ready() -> [Group] {
    var ready: [Group] = []
    while let first = pending.first, first.waiting.isEmpty || pending.count > Self.maximumPending {
      ready.append(pending.removeFirst())
      newestReleased = first.update.id
    }
    return ready
  }

  mutating func clear() {
    pending = []
    newestReleased = nil
  }

  private func isReleased(_ id: UInt32) -> Bool {
    guard let newestReleased else { return false }

    return !Self.precedes(newestReleased, id)
  }

  private static func precedes(_ earlier: UInt32, _ later: UInt32) -> Bool {
    Int32(bitPattern: later &- earlier) > 0
  }
}
