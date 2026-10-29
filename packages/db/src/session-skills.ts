import { SessionSkills } from "@codevisor/api"
import type Database from "better-sqlite3"
import { Schema } from "effect"

import { payloadRows } from "./common-rows.js"
import { jsonRecord } from "./event-payloads.js"

const isSkillList = Schema.is(SessionSkills.fields.skills)

const isCommandList = Schema.is(Schema.Array(Schema.String))

export const readSessionSkills = (
  sqlite: Database.Database,
  sessionId: string
): SessionSkills | undefined => {
  const raw = skillsPayload(sqlite, sessionId)
  const payload = raw === undefined ? undefined : jsonRecord(JSON.parse(raw))
  if (
    payload === undefined ||
    !isSkillList(payload.skills) ||
    typeof payload.invocationPrefix !== "string"
  ) {
    return undefined
  }
  return {
    invocationPrefix: payload.invocationPrefix,
    skills: payload.skills,
    ...(isCommandList(payload.commands) ? { commands: payload.commands } : {})
  }
}

const skillsPayload = (sqlite: Database.Database, sessionId: string): string | undefined =>
  payloadRows.maybe(sqlite.prepare(skillsSql).get(sessionId))?.payload

const skillsSql =
  "select payload from session_state where session_id = ? and state_key = 'available_skills_update'"
