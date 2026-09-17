import ACPKit
import Foundation
@testable import CodevisorCore

func transcriptStateItem(
  id: UUID = UUID(), sessionId: UUID, role: ServerTranscriptItem.Role = .assistant,
  text: String = "", messageId: String? = nil, hasDetails: Bool = false,
  plan: String? = nil, generating: Bool = false
) -> ServerTranscriptItem {
  ServerTranscriptItem(
    id: id.uuidString, sessionId: sessionId.uuidString, sequence: 0,
    role: role, text: text, createdAt: "2026-06-30T00:00:00.000Z", updatedAt: "2026-06-30T00:00:00.000Z",
    isGenerating: generating, hasDetails: hasDetails, planDocument: plan, messageId: messageId, revision: 1)
}
