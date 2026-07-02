import type { ConversationItem } from "@herdman/api"

// Folds the server's per-chunk conversation rows into displayable turns,
// mirroring the Swift client (ServerSessionTransport.conversationItems +
// TranscriptReducer): consecutive assistant rows all belong to ONE assistant
// turn — only a user message starts a new bubble. ACP messageId is the
// semantic boundary between assistant messages inside a turn, so a change of
// (non-null) messageId inserts a paragraph break rather than a new turn.
// System rows flush the running turn and are not displayed.
export function foldConversation(items: readonly ConversationItem[]): ConversationItem[] {
  const folded: ConversationItem[] = []
  // A system row flushes the running assistant turn: the next assistant row
  // starts a new turn instead of merging across the boundary.
  let turnFlushed = false
  for (const item of items) {
    if (item.role === "system") {
      turnFlushed = true
      continue
    }
    const last = folded[folded.length - 1]
    if (item.role === "assistant" && last != null && last.role === "assistant" && !turnFlushed) {
      const isMessageBoundary =
        last.messageId != null && item.messageId != null && last.messageId !== item.messageId
      folded[folded.length - 1] = {
        ...last,
        text: last.text + (isMessageBoundary ? "\n\n" : "") + item.text,
        messageId: item.messageId ?? last.messageId,
        isGenerating: last.isGenerating || item.isGenerating
      }
      continue
    }
    turnFlushed = false
    folded.push({ ...item })
  }
  return folded
}
