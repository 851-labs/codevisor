import type { CodexInputItem } from "./attachments.js"
import { CODEX_FAST_TIER, CODEX_MODES, CODEX_STANDARD_TIER, effectiveSpeed } from "./models.js"
import type { CodexSession } from "./session.js"

export const startCodexTurn = async (
  session: CodexSession,
  input: ReadonlyArray<CodexInputItem>
): Promise<void> => {
  const mode = CODEX_MODES.find((candidate) => candidate.id === session.currentModeId)
  const speed = effectiveSpeed(session)
  if (mode?.collaboration === "plan") session.collaborationEngaged = true
  const collaborationMode =
    session.currentModel.length > 0 &&
    (mode?.collaboration !== undefined || session.collaborationEngaged)
      ? {
          collaborationMode: {
            mode: mode?.collaboration ?? "default",
            settings: {
              developer_instructions: null,
              model: session.currentModel,
              reasoning_effort: session.currentEffort ?? null
            }
          }
        }
      : {}
  await session.client.request("turn/start", {
    input,
    threadId: session.threadId,
    ...(session.currentModel.length === 0 ? {} : { model: session.currentModel }),
    ...(session.currentEffort === undefined ? {} : { effort: session.currentEffort }),
    ...(session.reasoningSummariesRejected === true ? {} : { summary: "auto" }),
    ...(speed === undefined
      ? {}
      : { serviceTier: speed === "fast" ? CODEX_FAST_TIER : CODEX_STANDARD_TIER }),
    ...(mode === undefined
      ? {}
      : { approvalPolicy: mode.approvalPolicy, sandboxPolicy: mode.sandboxPolicy }),
    ...collaborationMode
  })
}
