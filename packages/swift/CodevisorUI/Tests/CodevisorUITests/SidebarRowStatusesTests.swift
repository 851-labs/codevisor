import CodevisorCore
import Foundation
import Testing
@testable import CodevisorUI

struct SidebarRowStatusesTests {
  private let start = Date(timeIntervalSince1970: 1_000)
  private let parent = UUID()
  private let child = UUID()
  private let grandchild = UUID()

  private func item(_ id: UUID, under parentId: UUID? = nil, agentMade: Bool = true) -> WorkspaceSidebarItem {
    WorkspaceSidebarItem(
      id: id, serverId: "studio", projectId: UUID(), routingChatIds: [],
      parent: parentId.map { WorkspaceParentLink(workspaceId: $0, linkedAt: start, isQuiet: agentMade) })
  }

  private var family: [WorkspaceSidebarItem] {
    [item(parent), item(child, under: parent), item(grandchild, under: child)]
  }

  private func status(
    _ activities: [UUID: SidebarChatActivity], items: [WorkspaceSidebarItem]? = nil, of id: UUID? = nil
  ) -> SidebarRowStatus? {
    SidebarRowStatuses(items ?? family) { activities[$0.id] }.status(of: id ?? parent)
  }

  private let working = SidebarChatActivity(isWorking: true)
  private let settingUp = SidebarChatActivity(isSettingUp: true)
  private let asking = SidebarChatActivity(request: .input)
  private let approving = SidebarChatActivity(request: .approval)

  @Test func idleChatsShowNothing() {
    #expect(status([parent: SidebarChatActivity()]) == nil)
  }

  @Test func ownTurnShowsWorkingSinceItStarted() {
    #expect(status([parent: SidebarChatActivity(isWorking: true, workingSince: start)]) == .working(since: start))
  }

  @Test func idleChatWithAWorkingChildIsWaiting() {
    #expect(status([parent: SidebarChatActivity(), child: working]) == .waiting)
  }

  @Test func grandchildSettingUpCountsAsWaiting() {
    #expect(status([grandchild: settingUp]) == .waiting)
  }

  @Test func childQuestionOutranksOwnTurnAndNamesTheChild() {
    #expect(status([parent: working, child: asking]) == .input(askingWorkspaceID: child))
  }

  @Test func grandchildOnAnotherMachineCanAsk() {
    let remote = WorkspaceSidebarItem(
      id: grandchild, serverId: "linux", projectId: UUID(), routingChatIds: [],
      parent: WorkspaceParentLink(workspaceId: child, linkedAt: start, isQuiet: true))
    let items = [item(parent), item(child, under: parent), remote]
    #expect(status([grandchild: asking], items: items) == .input(askingWorkspaceID: grandchild))
  }

  @Test func ownQuestionNamesItselfBeforeAChild() {
    #expect(status([parent: asking, child: asking]) == .input(askingWorkspaceID: parent))
  }

  @Test func anyQuestionOutranksAnyApproval() {
    #expect(status([parent: approving, grandchild: asking]) == .input(askingWorkspaceID: grandchild))
  }

  @Test func childApprovalOutranksOwnSetup() {
    #expect(status([parent: settingUp, child: approving]) == .approval(askingWorkspaceID: child))
  }

  @Test func setupOutranksWorking() {
    #expect(status([parent: SidebarChatActivity(isSettingUp: true, isWorking: true)]) == .settingUp)
  }

  @Test func ownFailuresShowFailedOrLimited() {
    #expect(status([parent: SidebarChatActivity(failure: .error)]) == .failed)
    #expect(status([parent: SidebarChatActivity(failure: .usageLimit)]) == .limited)
  }

  @Test func childFailuresDoNotRollUp() {
    #expect(status([child: SidebarChatActivity(failure: .error)]) == nil)
  }

  @Test func workingAndWaitingOutrankOwnFailure() {
    let failed = SidebarChatActivity(isWorking: true, failure: .error)
    #expect(status([parent: failed]) == .working(since: nil))
    #expect(status([parent: SidebarChatActivity(failure: .error), child: working]) == .waiting)
  }

  @Test func forksDoNotRollUp() {
    let items = [item(parent), item(child, under: parent, agentMade: false)]
    #expect(status([child: asking], items: items) == nil)
  }

  @Test func cyclicLinksStillResolve() {
    let items = [item(parent, under: child), item(child, under: parent)]
    #expect(status([child: working], items: items) == .waiting)
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
    let id = UUID()
    for status in [SidebarRowStatus.input(askingWorkspaceID: id), .approval(askingWorkspaceID: id), .failed, .limited] {
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

  @Test func elapsedTimeIsCompact() {
    #expect(SidebarRowStatus.elapsed(from: start, to: start.addingTimeInterval(42)) == "42s")
    #expect(SidebarRowStatus.elapsed(from: start, to: start.addingTimeInterval(185)) == "3m")
    #expect(SidebarRowStatus.elapsed(from: start, to: start.addingTimeInterval(3_900)) == "1h 5m")
  }
}
