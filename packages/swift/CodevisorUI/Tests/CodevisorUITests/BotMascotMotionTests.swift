import Testing
@testable import CodevisorUI

struct BotMascotMotionTests {
  private static let working = BotMascotActivity(isWorking: true, isWaitingOnAgents: false)
  private static let waiting = BotMascotActivity(isWorking: false, isWaitingOnAgents: true)
  private static let callingWhileWorking = BotMascotActivity(isWorking: true, isWaitingOnAgents: true)

  @Test("A busy bot works, and talking to or waiting on agents shows calling, open or not")
  func busyBotsIgnoreWhetherTheyAreOpen() {
    for isOpen in [true, false] {
      #expect(BotMascotMotion(Self.working, isOpen: isOpen) == .working)
      #expect(BotMascotMotion(Self.waiting, isOpen: isOpen) == .calling)
      #expect(BotMascotMotion(Self.callingWhileWorking, isOpen: isOpen) == .calling)
    }
  }

  @Test("A resting bot is idle and follows the pointer only while its chat is open; otherwise it sleeps")
  func restingBotSleepsUnlessOpen() {
    let open = BotMascotMotion(.resting, isOpen: true)
    let closed = BotMascotMotion(.resting, isOpen: false)

    #expect(open == .idle && open.followsPointer)
    #expect(closed == .sleeping && !closed.followsPointer)
  }
}
