import type { SessionSkills } from "@codevisor/api"
import type Database from "better-sqlite3"

import { jsonRecord } from "./event-payloads.js"

/// The session's latest `available_skills_update`, kept as session state.
export const readSessionSkills = (
  sqlite: Database.Database,
  sessionId: string
): SessionSkills | undefined => {
  const row = sqlite
    .prepare(
      "select payload from session_state where session_id = ? and state_key = 'available_skills_update'"
    )
    .get(sessionId) as { payload: string } | undefined
  const payload = row === undefined ? undefined : jsonRecord(JSON.parse(row.payload))
  if (
    payload === undefined ||
    !Array.isArray(payload.skills) ||
    typeof payload.invocationPrefix !== "string"
  ) {
    return undefined
  }
  return {
    invocationPrefix: payload.invocationPrefix,
    skills: payload.skills as SessionSkills["skills"]
  }
}
