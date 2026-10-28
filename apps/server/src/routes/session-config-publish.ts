import { decode, SessionConfigOption } from "@codevisor/api"
import { Schema } from "effect"

import {
  appendAndPublish,
  run,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { field } from "../unknown-values.js"
import { materializeRuntimeEvent } from "./session-events.js"

export const publishSessionConfigOptions = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  sessionId: string,
  configOptions: ReadonlyArray<SessionConfigOption>
): Promise<void> => {
  if (configOptions.length === 0) return
  const served = field(await run(services.db.getSessionRuntimeState(sessionId)), "configOptions")
  if (JSON.stringify(served) === JSON.stringify(configOptions)) return
  await materializeRuntimeEvent(
    services.db,
    fanout,
    serverId,
    { kind: "session.updated", subjectId: sessionId, payload: { configOptions } },
    sessionId
  )
}

export const publishSessionSelections = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  sessionId: string
): Promise<void> => {
  const session = await run(services.db.getSessionSummary(sessionId))
  await appendAndPublish(services.db, fanout, "session.updated", session.id, session)
}

export const persistedConfigOptions = (runtime: unknown): ReadonlyArray<SessionConfigOption> =>
  decode(Schema.Array(SessionConfigOption))(field(runtime, "configOptions"))
