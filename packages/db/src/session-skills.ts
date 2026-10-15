import { SessionSkills } from "@codevisor/api"
import type Database from "better-sqlite3"
import { Schema } from "effect"

import { payloadRows } from "./common-rows.js"
import { jsonRecord } from "./event-payloads.js"

const isSkillList = Schema.is(SessionSkills.fields.skills)

export const readSessionSkills = (
  sqlite: Database.Database,
  sessionId: string
): SessionSkills | undefined => {
  const row = payloadRows.maybe(
    sqlite
      .prepare(
        "select payload from session_state where session_id = ? and state_key = 'available_skills_update'"
      )
      .get(sessionId)
  )
  const payload = row === undefined ? undefined : jsonRecord(JSON.parse(row.payload))
  if (
    payload === undefined ||
    !isSkillList(payload.skills) ||
    typeof payload.invocationPrefix !== "string"
  ) {
    return undefined
  }
  return {
    invocationPrefix: payload.invocationPrefix,
    skills: payload.skills
  }
}
