struct ScreenSharingV2UpdateAssembly {
  struct Group {
    let update: ScreenSharingTileUpdate
    var waiting: Set<Int>
    var arrived: Set<Int> = []
    var decoded: [ScreenSharingV2DecodeContext] = []
  }

  enum Outcome {
    case decoded(ScreenSharingV2DecodeContext)
    case missing
  }

  static let maximumPending = 8

  private var pending: [Group] = []

  var waitingCount: Int { pending.count }

  mutating func received(_ update: ScreenSharingTileUpdate, tile: Int) {
    for index in pending.indices where pending[index].update.id != update.id {
      if !pending[index].arrived.contains(tile) { pending[index].waiting.remove(tile) }
    }
    if let index = pending.firstIndex(where: { $0.update.id == update.id }) {
      pending[index].arrived.insert(tile)
      return
    }

    var group = Group(update: update, waiting: update.tiles)
    group.arrived.insert(tile)
    pending.append(group)
  }

  mutating func resolve(update id: UInt32, tile: Int, _ outcome: Outcome) -> Bool {
    guard let index = pending.firstIndex(where: { $0.update.id == id }) else { return false }

    pending[index].waiting.remove(tile)
    if case .decoded(let context) = outcome { pending[index].decoded.append(context) }
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
    }
    return ready
  }

  mutating func clear() {
    pending = []
  }
}
