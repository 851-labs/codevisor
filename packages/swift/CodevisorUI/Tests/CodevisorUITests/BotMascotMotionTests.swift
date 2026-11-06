import Testing
@testable import CodevisorUI

struct BotMascotMotionTests {
  private static let working = BotMascotActivity(isInTurn: true, isTalkingToAgent: false, hasActiveAgents: true)
  private static let calling = BotMascotActivity(isInTurn: true, isTalkingToAgent: true, hasActiveAgents: true)
  private static let delegated = BotMascotActivity(isInTurn: false, isTalkingToAgent: false, hasActiveAgents: true)

  @Test("A bot in a turn calls while it talks to an agent and works otherwise, open or not")
  func turnsIgnoreWhetherTheBotIsOpen() {
    for isOpen in [true, false] {
      #expect(BotMascotMotion(Self.working, isOpen: isOpen) == .working)
      #expect(BotMascotMotion(Self.calling, isOpen: isOpen) == .calling)
    }
  }

  @Test("Between turns an open bot watches the pointer, whatever its agents are doing")
  func openBotWatchesBetweenTurns() {
    for activity in [BotMascotActivity.resting, Self.delegated] {
      let motion = BotMascotMotion(activity, isOpen: true)
      #expect(motion == .watching && motion.followsPointer)
    }
  }

  @Test("Between turns a closed bot stays awake without the pointer while its agents are active, else sleeps")
  func closedBotSleepsOnceItsAgentsAreDone() {
    let delegated = BotMascotMotion(Self.delegated, isOpen: false)
    let resting = BotMascotMotion(.resting, isOpen: false)

    #expect(delegated == .idle && !delegated.followsPointer && delegated.riveMode == "idle")
    #expect(resting == .sleeping && !resting.followsPointer)
  }
}
