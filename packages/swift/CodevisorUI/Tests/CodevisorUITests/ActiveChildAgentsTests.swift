import Testing
@testable import CodevisorUI

struct ActiveChildAgentsTests {
  private struct Child: Equatable {
    let name: String
    let activity: ChildAgentActivity
  }

  private let idle = Child(name: "idle", activity: .idle)
  private let firstWorker = Child(name: "first worker", activity: .working)
  private let secondWorker = Child(name: "second worker", activity: .working)
  private let firstWaiting = Child(name: "first waiting", activity: .waitingForUser)
  private let secondWaiting = Child(name: "second waiting", activity: .waitingForUser)

  private func active(_ children: [Child]) -> [Child] {
    ActiveChildAgents.select(children, activity: \.activity)
  }

  @Test func idleChildrenAreHidden() {
    #expect(active([idle, Child(name: "also idle", activity: .idle)]).isEmpty)
  }

  @Test func waitingChildrenComeFirstAndKeepTheirSidebarOrder() {
    let children = [firstWorker, idle, firstWaiting, secondWorker, secondWaiting]

    #expect(active(children) == [firstWaiting, secondWaiting, firstWorker, secondWorker])
  }

  @Test func waitingForUserWinsOverWorking() {
    #expect(ChildAgentActivity(isWaitingOnUser: true, isWorking: true) == .waitingForUser)
    #expect(ChildAgentActivity(isWaitingOnUser: false, isWorking: true) == .working)
    #expect(ChildAgentActivity(isWaitingOnUser: false, isWorking: false) == .idle)
  }

  @Test func overflowCountsChildrenPastTheLimit() {
    let children = [firstWaiting, secondWaiting, firstWorker, secondWorker]

    let overflow = ChildAgentsOverflow(children, limit: 2)

    #expect(overflow.shown == [firstWaiting, secondWaiting])
    #expect(overflow.hiddenCount == 2)
  }

  @Test func overflowIsEmptyWhenEveryChildFits() {
    let overflow = ChildAgentsOverflow([firstWaiting, firstWorker], limit: 3)

    #expect(overflow.shown == [firstWaiting, firstWorker])
    #expect(overflow.hiddenCount == 0)
  }
}
