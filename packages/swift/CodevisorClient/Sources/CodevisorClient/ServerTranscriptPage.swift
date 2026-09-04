import ACPKit
import CodevisorProtocol
import Foundation

public struct ServerTranscriptPage: Decodable, Equatable, Sendable {
  public var items: [ServerTranscriptItem]
  public var nextBefore: String?
  public var hasMore: Bool
  public var eventCursor: Int
  public var pendingQuestion: QuestionRequest?
  public var pendingPlanApproval: Bool
  public var backgroundTasks: [BackgroundTaskInfo]?
  public var goal: SessionGoal?
  public var sessionPlan: Plan?
  public var usage: ServerSessionUsage?
  /// The gate holding this session's prompts at this page's cursor; nil when
  /// nothing is held (and on servers that predate the field).
  public var updateGate: ServerSessionUpdateGate?

  public init(
    items: [ServerTranscriptItem],
    nextBefore: String? = nil,
    hasMore: Bool,
    eventCursor: Int,
    pendingQuestion: QuestionRequest? = nil,
    pendingPlanApproval: Bool = false,
    backgroundTasks: [BackgroundTaskInfo]? = nil,
    goal: SessionGoal? = nil,
    sessionPlan: Plan? = nil,
    usage: ServerSessionUsage? = nil,
    updateGate: ServerSessionUpdateGate? = nil
  ) {
    self.items = items
    self.nextBefore = nextBefore
    self.hasMore = hasMore
    self.eventCursor = eventCursor
    self.pendingQuestion = pendingQuestion
    self.pendingPlanApproval = pendingPlanApproval
    self.backgroundTasks = backgroundTasks
    self.goal = goal
    self.sessionPlan = sessionPlan
    self.usage = usage
    self.updateGate = updateGate
  }

  enum CodingKeys: String, CodingKey {
    case items
    case nextBefore
    case hasMore
    case eventCursor
    case pendingQuestion
    case pendingPlanApproval
    case backgroundTasks
    case goal
    case sessionPlan
    case usage
    case updateGate
  }

  public init(from decoder: any Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    items = try container.decode([ServerTranscriptItem].self, forKey: .items)
    nextBefore = try container.decodeIfPresent(String.self, forKey: .nextBefore)
    hasMore = try container.decode(Bool.self, forKey: .hasMore)
    eventCursor = try container.decode(Int.self, forKey: .eventCursor)
    pendingQuestion = try container.decodeIfPresent(QuestionRequest.self, forKey: .pendingQuestion)
    pendingPlanApproval =
      try container.decodeIfPresent(Bool.self, forKey: .pendingPlanApproval) ?? false
    backgroundTasks =
      try container.decodeIfPresent([BackgroundTaskInfo].self, forKey: .backgroundTasks)
    goal = try container.decodeIfPresent(SessionGoal.self, forKey: .goal)
    sessionPlan = try container.decodeIfPresent(Plan.self, forKey: .sessionPlan)
    usage = try container.decodeIfPresent(ServerSessionUsage.self, forKey: .usage)
    updateGate = try container.decodeIfPresent(ServerSessionUpdateGate.self, forKey: .updateGate)
  }
}
