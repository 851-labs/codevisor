import Testing
@testable import CodevisorUI

struct BotMascotMotionTests {
  private static let working = activity(isInTurn: true, hasWorkingAgents: true)
  private static let calling = activity(isInTurn: true, isTalkingToAgent: true, hasWorkingAgents: true)
  private static let delegated = activity(hasWorkingAgents: true)
  private static let blockedOnYou = activity(hasAgentsWaitingOnYou: true)
  private static let justCreated = activity(hasMessages: false)

  @Test("A bot in a turn calls while it talks to an agent and works otherwise, open or not")
  func turnsIgnoreWhetherTheBotIsOpen() {
    for isOpen in [true, false] {
      #expect(BotMascotMotion(Self.working, isOpen: isOpen) == .working)
      #expect(BotMascotMotion(Self.calling, isOpen: isOpen) == .calling)
    }
  }

  @Test("Between turns an open bot watches the pointer, whatever its agents are doing")
  func openBotWatchesBetweenTurns() {
    for activity in [BotMascotActivity.resting, Self.delegated, Self.blockedOnYou] {
      let motion = BotMascotMotion(activity, isOpen: true)
      #expect(motion == .watching && motion.followsPointer)
    }
  }

  @Test("A closed bot waits while its agents work, and plays the waiting animation")
  func closedBotWaitsOnWorkingAgents() {
    let motion = BotMascotMotion(Self.delegated, isOpen: false)

    #expect(motion == .waiting && !motion.followsPointer && motion.riveMode == "waiting")
  }

  @Test("A closed bot stays awake while an agent waits on you or before its first message, else sleeps")
  func closedBotSleepsOnceNothingNeedsIt() {
    for activity in [Self.blockedOnYou, Self.justCreated] {
      let motion = BotMascotMotion(activity, isOpen: false)
      #expect(motion == .idle && !motion.followsPointer && motion.riveMode == "idle")
    }
    #expect(BotMascotMotion(.resting, isOpen: false) == .sleeping)
  }

  private static func activity(
    isInTurn: Bool = false, isTalkingToAgent: Bool = false, hasWorkingAgents: Bool = false,
    hasAgentsWaitingOnYou: Bool = false, hasMessages: Bool = true
  ) -> BotMascotActivity {
    BotMascotActivity(
      isInTurn: isInTurn, isTalkingToAgent: isTalkingToAgent, hasWorkingAgents: hasWorkingAgents,
      hasAgentsWaitingOnYou: hasAgentsWaitingOnYou, hasMessages: hasMessages)
  }
}
