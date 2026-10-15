import type Database from "better-sqlite3"

import { integer, nullable, rowReader, text } from "./row-reader.js"

export const idRows = rowReader({ id: text })

export const nameRows = rowReader({ name: text })

export const valueRows = rowReader({ value: text })

export const payloadRows = rowReader({ payload: text })

export const entryKeyRows = rowReader({ entry_key: text })

export const countRows = rowReader({ count: integer })

export const cursorRows = rowReader({ cursor: integer })

export const revisionRows = rowReader({ revision: integer })

export const pendingQuestionRows = rowReader({ pending_question: nullable(text) })

export const backfillJobRows = rowReader({
  state: text,
  cursor: nullable(text),
  completed: integer,
  total: integer
})

export const readInstanceMeta = (sqlite: Database.Database, key: string): string | undefined =>
  valueRows.maybe(sqlite.prepare("select value from instance_meta where key = ?").get(key))?.value
