struct ScreenSharingDisplaySwitcher {
  struct Beat {
    let number: Int
    let carrying: String?
  }

  struct Reading {
    var showsDisplay: Bool
    var result: ScreenSharingDisplaySwitch?
  }

  private struct Wanted {
    let displayId: String
    var firstBeat: Int?
  }

  private var wanted: Wanted?
  private var carried: String?
  private var sent = 0
  private var newestAnswered = 0

  var isCarrying: Bool { carried != nil }

  mutating func want(_ displayId: String) {
    wanted = Wanted(displayId: displayId)
  }

  mutating func giveUp(on displayId: String) -> Bool {
    guard wanted?.displayId == displayId else { return false }

    wanted = nil
    return true
  }

  mutating func beginBeat() -> Beat {
    sent += 1
    guard carried == nil, let displayId = wanted?.displayId else { return Beat(number: sent, carrying: nil) }

    carried = displayId
    if wanted?.firstBeat == nil { wanted?.firstBeat = sent }
    return Beat(number: sent, carrying: displayId)
  }

  mutating func finish(_ beat: Beat) -> Bool {
    guard let carrying = beat.carrying else { return false }

    carried = nil
    return wanted != nil && wanted?.displayId != carrying
  }

  mutating func read(_ reply: ScreenSharingHostReply, of beat: Beat) -> Reading {
    let isNewest = beat.number > newestAnswered
    if isNewest { newestAnswered = beat.number }
    guard let wanted, let firstBeat = wanted.firstBeat, beat.number >= firstBeat else {
      return Reading(showsDisplay: isNewest)
    }

    if reply.base.display?.id == wanted.displayId, !reply.isStillSwitchingDisplay {
      self.wanted = nil
      newestAnswered = sent
      return Reading(showsDisplay: true, result: .init(displayId: wanted.displayId, phase: .confirmed))
    }
    guard beat.carrying == wanted.displayId, reply.cannotSwitchDisplay else { return Reading(showsDisplay: isNewest) }

    self.wanted = nil
    let phase = ScreenSharingDisplaySwitch.Phase.unavailable(message: reply.base.message)
    return Reading(showsDisplay: isNewest, result: .init(displayId: wanted.displayId, phase: phase))
  }
}
