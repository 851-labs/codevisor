import type { CodevisorServerServices, EventFanout } from "./server-context-types.js"
import { appendAndPublish, run } from "./server-http.js"

export const clearStoppedTasks = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string
): Promise<void> => {
  const page = await run(services.db.getTranscriptPage(sessionId, undefined, 1))
  if (page.backgroundTasks!.length === 0) return

  await appendAndPublish(services.db, fanout, "session.updated", sessionId, {
    backgroundTasks: [],
    serverId
  })
}
