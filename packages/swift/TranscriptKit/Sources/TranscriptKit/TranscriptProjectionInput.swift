import CodevisorProtocol
import Foundation

public struct TranscriptProjectionInput: Sendable {
  public enum ConnectionStatus: Equatable, Sendable {
    case idle
    case connecting(String)
    case failed(String)
  }

  public let settledConversation: [ConversationItem]
  public let pendingUserMessage: UserMessage?
  public let activeItem: ConversationItem?
  public var hasActiveItem: Bool { activeItem != nil }
  public let setupPhases: [SessionSetupPhase]
  public let waitingBackgroundTaskDescription: String?
  public let waitingHarnessUpdateName: String?
  public let isLoadingInitialHistory: Bool
  public let serverWaitMessage: String?
  public let sessionErrorMessage: String?
  public let status: ConnectionStatus
  public let activityMessage: String?
  public let botConversation: TranscriptBotConversation?

  public init(
    settledConversation: [ConversationItem],
    pendingUserMessage: UserMessage?,
    activeItem: ConversationItem?,
    setupPhases: [SessionSetupPhase],
    waitingBackgroundTaskDescription: String?,
    waitingHarnessUpdateName: String?,
    isLoadingInitialHistory: Bool,
    serverWaitMessage: String?,
    sessionErrorMessage: String?,
    status: ConnectionStatus,
    activityMessage: String? = nil,
    botConversation: TranscriptBotConversation? = nil
  ) {
    self.settledConversation = settledConversation
    self.pendingUserMessage = pendingUserMessage
    self.activeItem = activeItem
    self.setupPhases = setupPhases
    self.waitingBackgroundTaskDescription = waitingBackgroundTaskDescription
    self.waitingHarnessUpdateName = waitingHarnessUpdateName
    self.isLoadingInitialHistory = isLoadingInitialHistory
    self.serverWaitMessage = serverWaitMessage
    self.sessionErrorMessage = sessionErrorMessage
    self.status = status
    self.activityMessage = activityMessage
    self.botConversation = botConversation
  }
}
