import { isRecord } from "./internal.js"
import type { CodexSession } from "./session.js"

export const codexThreadTitle = (thread: Record<string, unknown>): string | undefined => {
  for (const value of [thread.name, thread.preview]) {
    if (typeof value !== "string") continue
    const title = value.trim()
    if (title.length > 0) return title
  }
  return undefined
}

export const handleThreadNameUpdated = (
  session: CodexSession,
  payload: Record<string, unknown>
): void => {
  session.titleGenerator?.observeName(payload.threadName)
  const title = typeof payload.threadName === "string" ? payload.threadName.trim() : undefined
  if (isBlankTitle(title)) {
    void refreshCodexSessionTitle(session)
    return
  }

  void emitCodexSessionTitle(session, title)
}

export const refreshCodexSessionTitle = async (session: CodexSession): Promise<void> => {
  try {
    const response: unknown = await session.client.request("thread/read", {
      includeTurns: false,
      threadId: session.threadId
    })
    const thread = isRecord(response) && isRecord(response.thread) ? response.thread : undefined
    session.titleGenerator?.observeName(thread?.name)
    await emitCodexSessionTitle(session, threadName(thread))
  } catch {}
}

const isBlankTitle = (title: string | undefined): boolean =>
  title === undefined || title.length === 0

const threadName = (thread: Record<string, unknown> | undefined): string | undefined =>
  typeof thread?.name === "string" && thread.name.trim().length > 0 ? thread.name.trim() : undefined

const emitCodexSessionTitle = async (
  session: CodexSession,
  title: string | undefined
): Promise<void> => {
  if (title === undefined || title === session.lastHarnessTitle) return
  session.lastHarnessTitle = title
  await session.emit({
    kind: "session.updated",
    payload: { sessionUpdate: "session_info_update", title },
    subjectId: session.key
  })
}
