import { randomUUID } from "node:crypto"

import Database from "better-sqlite3"

import { readInstanceMeta } from "./common-rows.js"

export const resolveServerIdentity = (filename: string): string => {
  const sqlite = new Database(filename)
  try {
    sqlite.exec(`
      create table if not exists instance_meta (
        key text primary key,
        value text not null
      );
    `)
    const existing = readInstanceMeta(sqlite, "machine-id")
    if (existing !== undefined) return existing
    const id = randomUUID()
    sqlite.prepare("insert into instance_meta (key, value) values ('machine-id', ?)").run(id)
    return id
  } finally {
    sqlite.close()
  }
}
