import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { integer, rowReader } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"
import type { CodevisorDatabaseService } from "./service.js"

const freshRows = rowReader({ fresh: integer })

export const clearFreshAgentSessionSql =
  "update sessions set fresh_agent_session_id = null where id = ? and fresh_agent_session_id is not null"

const freshSql = {
  mark: "update sessions set fresh_agent_session_id = ? where id = ?",
  read: `select coalesce(fresh_agent_session_id = agent_session_id, 0) as fresh
           from sessions where id = ?`
}

export const makeFreshAgentSessionsService = (
  context: ServiceContext
): Pick<CodevisorDatabaseService, "markAgentSessionFresh" | "isAgentSessionFresh"> => {
  const { sqlite } = context
  return {
    markAgentSessionFresh: (sessionId, agentSessionId) =>
      attempt("markAgentSessionFresh", () => {
        sqlite.prepare(freshSql.mark).run(agentSessionId, canonicalUuid(sessionId))
      }),
    isAgentSessionFresh: (sessionId) =>
      attempt("isAgentSessionFresh", () => {
        const row = freshRows.maybe(sqlite.prepare(freshSql.read).get(canonicalUuid(sessionId)))
        return row?.fresh === 1
      })
  }
}
