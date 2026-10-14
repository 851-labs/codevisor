import CoreGraphics
import Foundation
import MarkdownCore

public enum TranscriptWorkedSectionKind: String, Sendable, Equatable, Hashable {
  case planning
  case implementation

  var layoutComponent: String { rawValue }
}

public struct TranscriptWorkedSectionIdentity: Sendable, Equatable, Hashable {
  public let messageID: UUID
  public let kind: TranscriptWorkedSectionKind

  public init(messageID: UUID, kind: TranscriptWorkedSectionKind) {
    self.messageID = messageID
    self.kind = kind
  }
}

public enum TranscriptWorkedSectionRowRole: Sendable, Equatable {
  case header(defaultExpanded: Bool, isFixedExpanded: Bool)
  case content
}

public struct TranscriptWorkedSectionMembership: Sendable, Equatable {
  public let identity: TranscriptWorkedSectionIdentity
  public let role: TranscriptWorkedSectionRowRole

  public init(
    identity: TranscriptWorkedSectionIdentity,
    role: TranscriptWorkedSectionRowRole
  ) {
    self.identity = identity
    self.role = role
  }
}

public struct TranscriptWorkedSectionHeader: Sendable, Equatable {
  public let message: AssistantMessage
  public let kind: TranscriptWorkedSectionKind

  public init(message: AssistantMessage, kind: TranscriptWorkedSectionKind) {
    self.message = message
    self.kind = kind
  }
}

public struct TranscriptActiveWorkedSectionHeader: Sendable, Equatable {
  public let messageID: UUID
  public let kind: TranscriptWorkedSectionKind

  public init(messageID: UUID, kind: TranscriptWorkedSectionKind) {
    self.messageID = messageID
    self.kind = kind
  }
}

public struct TranscriptWorkedItemReference: Sendable, Equatable {
  public let messageID: UUID
  public let section: TranscriptWorkedSectionKind
  public let itemID: String

  public init(
    messageID: UUID,
    section: TranscriptWorkedSectionKind,
    itemID: String
  ) {
    self.messageID = messageID
    self.section = section
    self.itemID = itemID
  }
}

public struct TranscriptSettledWorkedItem: Sendable, Equatable {
  public let message: AssistantMessage
  public let reference: TranscriptWorkedItemReference

  public init(message: AssistantMessage, reference: TranscriptWorkedItemReference) {
    self.message = message
    self.reference = reference
  }
}
