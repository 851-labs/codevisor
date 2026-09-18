import CodevisorProtocol
import Foundation

/// Immutable transcript input copied from the UI actor before row projection.
/// All expensive, transcript-wide work operates on this value on the
/// projection actor; AppKit/UIKit only mount the resulting visible rows.
public struct TranscriptProjectionInput: Sendable {
  public enum ConnectionStatus: Equatable, Sendable {
    case idle
    case connecting(String)
    case failed(String)
  }

  public let settledConversation: [ConversationItem]
  public let pendingUserMessage: UserMessage?
  /// Immutable value represented by the projected active row. The native
  /// row may observe newer token content only while the live item keeps this
  /// identity; at a turn boundary this snapshot keeps the old response on
  /// screen until the replacement projection commits.
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
    activityMessage: String? = nil
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
  }
}
