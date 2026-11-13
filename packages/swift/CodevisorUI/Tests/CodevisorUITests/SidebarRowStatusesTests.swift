import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct SidebarRowStatusesTests {
  private let start = Date(timeIntervalSince1970: 1_000)
  private let main = ChatSession(projectId: UUID(), serverId: "studio")

  private func subAgent(
    of owner: ChatSession? = nil, serverId: String = "studio", isDetached: Bool = false, isArchived: Bool = false,
    forked: Bool = false
  ) -> ChatSession {
    let reference = AgentReference(agentId: (owner ?? main).id, machineId: (owner ?? main).serverId)
    return ChatSession(
      projectId: UUID(), serverId: serverId, createdByAgent: forked ? nil : reference, isDetached: isDetached,
      isArchived: isArchived, forkedFromAgent: forked ? reference : nil)
  }

  private func status(
    _ activities: [UUID: SidebarChatActivity], chats: [ChatSession] = [], shownInRow: [ChatSession] = []
  ) -> SidebarRowStatus? {
    let row = WorkspaceSidebarItem(
      id: UUID(), serverId: "studio", projectId: UUID(), routingChatIds: ([main] + shownInRow).map(\.id))
    return SidebarRowStatuses(
      [row], chats: [main] + shownInRow + chats, mainChat: { _ in main },
      activity: { activities[$0.id] ?? SidebarChatActivity() }
    ).status(of: row.id)
  }

  private let working = SidebarChatActivity(isWorking: true)
  private let settingUp = SidebarChatActivity(isSettingUp: true)
  private let asking = SidebarChatActivity(request: .input)
  private let approving = SidebarChatActivity(request: .approval)

  @Test("An agent's own row reads the same as its workspace row would: its own state, then a busy sub-agent")
  func agentRowStatus() {
    let helper = subAgent()
    let activities = [helper.id: working]
    let status = { (chat: ChatSession, known: [UUID: SidebarChatActivity]) in
      SidebarRowStatuses.status(of: chat, among: [main, helper]) { known[$0.id] ?? SidebarChatActivity() }
    }

    #expect(status(helper, activities) == .working(since: nil))
    #expect(status(main, activities) == .waiting)
    #expect(status(main, [main.id: asking, helper.id: working]) == .input)
    #expect(status(main, [:]) == nil)
  }

  @Test func idleChatsShowNothing() {
    #expect(status([main.id: SidebarChatActivity()]) == nil)
  }

  @Test func ownTurnShowsWorkingSinceItStarted() {
    #expect(status([main.id: SidebarChatActivity(isWorking: true, workingSince: start)]) == .working(since: start))
  }

  @Test func idleMainChatWithAWorkingSubAgentInItsWorkspaceIsWaiting() {
    let child = subAgent()
    #expect(status([child.id: working], shownInRow: [child]) == .waiting)
  }

  @Test func subAgentsWithoutAWorkspaceOrOnAnotherMachineCount() {
    for child in [subAgent(), subAgent(serverId: "linux")] {
      #expect(status([child.id: settingUp], chats: [child]) == .waiting)
    }
  }

  @Test func onlyAgentsTheMainChatStartedCount() {
    let other = ChatSession(projectId: UUID(), serverId: "studio")
    let childOfOther = subAgent(of: other)
    let child = subAgent()
    let grandchild = subAgent(of: child)
    #expect(status([other.id: working, childOfOther.id: working], chats: [childOfOther], shownInRow: [other]) == nil)
    #expect(status([grandchild.id: working], chats: [child, grandchild]) == nil)
  }

  @Test func detachedArchivedAndForkedAgentsDoNotCount() {
    let agents = [subAgent(isDetached: true), subAgent(isArchived: true), subAgent(forked: true)]
    let activities = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, working) })
    #expect(status(activities, chats: agents) == nil)
  }

  @Test func subAgentQuestionsAndFailuresStayOnTheSubAgent() {
    let child = subAgent()
    #expect(status([child.id: asking], chats: [child]) == nil)
    #expect(status([child.id: approving], chats: [child]) == nil)
    #expect(status([child.id: SidebarChatActivity(failure: .error)], chats: [child]) == nil)
  }

  @Test func ownQuestionAndApprovalOutrankWorking() {
    let child = subAgent()
    #expect(status([main.id: SidebarChatActivity(request: .input, isWorking: true)]) == .input)
    #expect(status([main.id: approving, child.id: working], chats: [child]) == .approval)
  }

  @Test func setupOutranksWorking() {
    #expect(status([main.id: SidebarChatActivity(isSettingUp: true, isWorking: true)]) == .settingUp)
  }

  @Test func ownFailuresShowFailedOrLimited() {
    #expect(status([main.id: SidebarChatActivity(failure: .error)]) == .failed)
    #expect(status([main.id: SidebarChatActivity(failure: .usageLimit)]) == .limited)
  }

  @Test func workingAndWaitingOutrankOwnFailure() {
    let child = subAgent()
    #expect(status([main.id: SidebarChatActivity(isWorking: true, failure: .error)]) == .working(since: nil))
    #expect(status([main.id: SidebarChatActivity(failure: .error), child.id: working], chats: [child]) == .waiting)
  }

  @Test func chatSessionsMapToRequests() {
    let project = UUID()
    let question = ChatSession(projectId: project, actionRequired: true, actionRequiredKind: "question")
    let permission = ChatSession(projectId: project, actionRequired: true, actionRequiredKind: "approval")
    let plan = ChatSession(projectId: project, pendingPlanApproval: true)
    #expect(SidebarChatActivity(session: question, isWorking: false).request == .input)
    #expect(SidebarChatActivity(session: permission, isWorking: false).request == .approval)
    #expect(SidebarChatActivity(session: plan, isWorking: false).request == .approval)
  }

  @Test func chatSessionsCarryTurnStartAndFailure() {
    let session = ChatSession(
      projectId: UUID(), sidebarState: .inProgress, sidebarStateChangedAt: start, lastTurnFailure: .usageLimit)
    let activity = SidebarChatActivity(session: session, isWorking: true)
    #expect(activity.workingSince == start)
    #expect(activity.failure == .usageLimit)
  }

  @Test func subtitleAfterStatusStartsWithTheSharedSeparator() {
    #expect(SidebarRowSubtitle.text("bacon-biscuits · main", followingStatus: true) == " · bacon-biscuits · main")
  }

  @Test func subtitleWithoutStatusHasNoLeadingSeparator() {
    #expect(SidebarRowSubtitle.text("bacon-biscuits · main", followingStatus: false) == "bacon-biscuits · main")
  }

  @Test func attentionAndFailureSymbolsReplaceTheLeadingIconEvenWhenUnread() {
    for status in [SidebarRowStatus.input, .approval, .failed, .limited] {
      #expect(status.replacesLeadingIcon(isUnread: true))
    }
  }

  @Test func waitingYieldsTheLeadingSlotToTheUnreadDot() {
    #expect(SidebarRowStatus.waiting.replacesLeadingIcon(isUnread: false))
    #expect(!SidebarRowStatus.waiting.replacesLeadingIcon(isUnread: true))
  }

  @Test func workingAndSetupKeepTheAnimatedLeadingIndicator() {
    #expect(!SidebarRowStatus.working(since: start).replacesLeadingIcon(isUnread: false))
    #expect(!SidebarRowStatus.settingUp.replacesLeadingIcon(isUnread: false))
  }

  @Test func botRowsShowStaticSymbolsEvenWithTheLabelOff() {
    #expect(SidebarBotStatusBadge.isVisible(.failed, showsLabel: false))
    #expect(SidebarBotStatusBadge.isVisible(.waiting, showsLabel: false))
  }

  @Test func botRowsLeaveWorkingToTheTypingBubbleUnlessTheLabelIsOn() {
    #expect(!SidebarBotStatusBadge.isVisible(.working(since: start), showsLabel: false))
    #expect(!SidebarBotStatusBadge.isVisible(.settingUp, showsLabel: false))
    #expect(SidebarBotStatusBadge.isVisible(.working(since: start), showsLabel: true))
  }

  @Test func labelsNameEachState() {
    let titles = [
      SidebarRowStatus.working(since: nil), .settingUp, .waiting, .input,
      .approval, .failed, .limited,
    ].map(\.title)
    #expect(titles == ["Working", "Setting up", "Waiting", "Needs Input", "Needs Approval", "Failed", "Usage Limit"])
  }

  @Test func onlyAttentionAndFailureStatesAreColoured() {
    for status in [SidebarRowStatus.working(since: nil), .settingUp, .waiting] {
      #expect(status.tone == .quiet)
    }
    for status in [SidebarRowStatus.input, .approval, .limited] {
      #expect(status.tone == .attention)
    }
    #expect(SidebarRowStatus.failed.tone == .failure)
  }

  @Test func elapsedTimeIsCompact() {
    #expect(SidebarRowStatus.elapsed(from: start, to: start.addingTimeInterval(42)) == "42s")
    #expect(SidebarRowStatus.elapsed(from: start, to: start.addingTimeInterval(185)) == "3m")
    #expect(SidebarRowStatus.elapsed(from: start, to: start.addingTimeInterval(3_900)) == "1h 5m")
  }
}
