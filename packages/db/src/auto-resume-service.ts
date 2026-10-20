import { isoTimestamp } from "@codevisor/api"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { integer, literal, nullable, rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export type AutoResumeState = "waiting" | "resuming"

export interface AutoResumeRecord {
  readonly sessionId: string
  readonly harnessId: string
  readonly harnessAccountId?: string
  readonly state: AutoResumeState
  readonly resetsAt?: string
  readonly checkAt: string
  readonly checks: number
}

export interface AutoResumeService {
  readonly saveAutoResume: (
    record: AutoResumeRecord
  ) => Effect.Effect<AutoResumeRecord, DatabaseError>
  readonly getAutoResume: (
    sessionId: string
  ) => Effect.Effect<AutoResumeRecord | undefined, DatabaseError>
  readonly listWaitingAutoResumes: Effect.Effect<ReadonlyArray<AutoResumeRecord>, DatabaseError>
  readonly deleteAutoResume: (sessionId: string) => Effect.Effect<boolean, DatabaseError>
}

export const makeAutoResumeService = (context: ServiceContext): AutoResumeService => {
  const { sqlite, getSession } = context

  return {
    saveAutoResume: (record) =>
      attempt("saveAutoResume", () => {
        const saved = { ...record, sessionId: canonicalUuid(record.sessionId) }
        getSession(saved.sessionId)
        sqlite.prepare(autoResumeSql.upsert).run(...upsertValues(saved))
        return saved
      }),
    getAutoResume: (sessionId) =>
      attempt("getAutoResume", () => {
        const row = autoResumeRows.maybe(
          sqlite.prepare(autoResumeSql.bySession).get(canonicalUuid(sessionId))
        )
        return row === undefined ? undefined : recordFromRow(row)
      }),
    listWaitingAutoResumes: attempt("listWaitingAutoResumes", () =>
      autoResumeRows.all(sqlite.prepare(autoResumeSql.waitingByCheck).all()).map(recordFromRow)
    ),
    deleteAutoResume: (sessionId) =>
      attempt(
        "deleteAutoResume",
        () => sqlite.prepare(autoResumeSql.delete).run(canonicalUuid(sessionId)).changes > 0
      )
  }
}

const upsertValues = (record: AutoResumeRecord) =>
  [
    record.sessionId,
    record.harnessId,
    record.harnessAccountId ?? null,
    record.state,
    record.resetsAt ?? null,
    record.checkAt,
    record.checks,
    isoTimestamp()
  ] as const

const recordFromRow = (row: AutoResumeRow): AutoResumeRecord => ({
  sessionId: row.session_id,
  harnessId: row.harness_id,
  ...(row.harness_account_id === null ? {} : { harnessAccountId: row.harness_account_id }),
  state: row.state,
  ...(row.resets_at === null ? {} : { resetsAt: row.resets_at }),
  checkAt: row.check_at,
  checks: row.checks
})

interface AutoResumeRow {
  readonly session_id: string
  readonly harness_id: string
  readonly harness_account_id: string | null
  readonly state: AutoResumeState
  readonly resets_at: string | null
  readonly check_at: string
  readonly checks: number
  readonly created_at: string
}

const autoResumeRows = rowReader<AutoResumeRow>({
  session_id: text,
  harness_id: text,
  harness_account_id: nullable(text),
  state: literal("waiting", "resuming"),
  resets_at: nullable(text),
  check_at: text,
  checks: integer,
  created_at: text
})

const autoResumeSql = {
  upsert: `insert into session_auto_resumes
    (session_id, harness_id, harness_account_id, state, resets_at, check_at, checks, created_at)
    values (?, ?, ?, ?, ?, ?, ?, ?)
    on conflict(session_id) do update set
      harness_id = excluded.harness_id,
      harness_account_id = excluded.harness_account_id,
      state = excluded.state,
      resets_at = excluded.resets_at,
      check_at = excluded.check_at,
      checks = excluded.checks`,
  bySession: "select * from session_auto_resumes where session_id = ?",
  waitingByCheck: `select * from session_auto_resumes
    where state = 'waiting' order by check_at, created_at, rowid`,
  delete: "delete from session_auto_resumes where session_id = ?"
}
