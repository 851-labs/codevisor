enum EncodeLabSettledFrames {
  static let holdTicks = 30

  static func select(_ events: [EncodeLabFrameEvent], endTick: Int, from firstTick: Int) -> Set<Int> {
    var settled: Set<Int> = []
    var versionStart = 0
    for index in events.indices {
      let next = events.indices.contains(index + 1) ? events[index + 1] : nil
      guard next?.version != events[index].version else { continue }

      let heldTicks = (next?.tick ?? endTick) - events[versionStart].tick
      if heldTicks >= holdTicks && events[index].tick >= firstTick { settled.insert(events[index].frame) }
      versionStart = index + 1
    }
    return settled
  }
}
