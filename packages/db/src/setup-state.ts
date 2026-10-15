import type { TranscriptBodyPage } from "@codevisor/api"
import type Database from "better-sqlite3"

import { jsonRecord } from "./event-payloads.js"
import { parseJsonObject } from "./json-column.js"
import { integer, rowReader, text } from "./row-reader.js"

const nextPositionRows = rowReader({ n: integer })

const setupRows = rowReader({
  subject_id: text,
  kind: text,
  revision: integer,
  created_at: text,
  text_length: integer,
  payload: text
})

const setupChunkRows = rowReader({ position: integer, text })

export const projectSetupState = (
  db: Database.Database,
  subject: string,
  kind: string,
  revision: number,
  createdAt: string,
  raw: unknown
): void => {
  if (kind !== "worktree.setup" && kind !== "project.setup") return
  const payload = jsonRecord(raw)
  if (payload === undefined) return
  const line =
    typeof payload.line === "string"
      ? `[${typeof payload.stream === "string" ? payload.stream : "stdout"}] ${payload.line}\n`
      : ""
  const metadata = { ...payload, line: undefined }
  db.prepare(
    `insert into setup_state(subject_id, kind, revision, created_at, payload) values (?, ?, ?, ?, ?)
    on conflict(subject_id, kind) do update set revision = excluded.revision,
      payload = case when json_extract(excluded.payload, '$.state') = 'log' then setup_state.payload else excluded.payload end`
  ).run(subject, kind, revision, createdAt, JSON.stringify(metadata))
  let position = nextPositionRows.one(
    db
      .prepare(
        "select coalesce(max(position), -1) + 1 as n from setup_text_chunks where subject_id = ? and kind = ?"
      )
      .get(subject, kind)
  ).n
  for (let offset = 0; offset < line.length;) {
    let end = Math.min(offset + 8192, line.length)
    if (
      end < line.length &&
      line.charCodeAt(end - 1) >= 0xd800 &&
      line.charCodeAt(end - 1) <= 0xdbff
    )
      end--
    db.prepare(
      "insert into setup_text_chunks(subject_id, kind, position, text) values (?, ?, ?, ?)"
    ).run(subject, kind, position++, line.slice(offset, end))
    offset = end
  }
  db.prepare(
    "update setup_state set text_length = text_length + ? where subject_id = ? and kind = ?"
  ).run(line.length, subject, kind)
}

const accessibleSetup = `select setup.* from setup_state setup join sessions s on s.id = ?
  where setup.subject_id = s.id or (setup.kind = 'project.setup' and setup.subject_id = s.project_id)
    or (setup.kind = 'worktree.setup' and setup.subject_id in (
      select id from worktrees where project_id = s.project_id and name = s.worktree_name))`

export const sessionSetupState = (db: Database.Database, sessionId: string): unknown[] => {
  const rows = setupRows.all(db.prepare(accessibleSetup).all(sessionId))
  return rows.map((row) => ({
    ...parseJsonObject(row.payload),
    id: `${row.kind}:${row.subject_id}`,
    kind: row.kind,
    subjectId: row.subject_id,
    createdAt: row.created_at,
    ...(row.text_length === 0
      ? {}
      : {
          resource: {
            itemId: `setup:${row.subject_id}`,
            entryKey: row.kind,
            fields: [
              { name: "text", revision: 0, encoding: "text", sizeBytes: row.text_length * 2 }
            ]
          }
        })
  }))
}

export const readSetupBodyPage = (
  db: Database.Database,
  sessionId: string,
  itemId: string,
  key: string,
  position: number
): TranscriptBodyPage | undefined => {
  const subject = itemId.slice(6)
  const allowed = db
    .prepare(`select 1 from (${accessibleSetup}) where subject_id = ? and kind = ?`)
    .get(sessionId, subject, key)
  if (allowed === undefined) return undefined
  const rows = setupChunkRows.all(
    db
      .prepare(
        "select position, text from setup_text_chunks where subject_id = ? and kind = ? and position >= ? order by position limit 2"
      )
      .all(subject, key, position)
  )
  return rows[0] === undefined
    ? undefined
    : {
        revision: 0,
        encoding: "text",
        ...rows[0],
        ...(rows[1] === undefined ? {} : { nextPosition: rows[1].position })
      }
}
