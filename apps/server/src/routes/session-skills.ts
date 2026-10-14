import { skillsUpdateEvent, type AgentSessionMetadata } from "@codevisor/agent-runtime"

import { run, type CodevisorServerServices, type EventFanout } from "../server-context.js"
import { materializeRuntimeEvent } from "./session-events.js"

export const publishSessionSkills = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  metadata: AgentSessionMetadata
): Promise<void> => {
  if (metadata.skills === undefined) return
  const current = await run(services.db.getSessionSkills(sessionId))
  if (JSON.stringify(current) === JSON.stringify(metadata.skills)) return
  await materializeRuntimeEvent(
    services.db,
    fanout,
    serverId,
    skillsUpdateEvent(sessionId, metadata.skills),
    sessionId
  )
}
