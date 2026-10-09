import { skillsUpdateEvent, type AgentSessionMetadata } from "@codevisor/agent-runtime"

import { run, type CodevisorServerServices, type EventFanout } from "../server-context.js"
import { materializeRuntimeEvent } from "./session-events.js"

/// Providers report the skills they found while starting as metadata (the
/// runtime drops output emitted before a session is registered). Record
/// them as the session's skills snapshot unless it already says the same.
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
