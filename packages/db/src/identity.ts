import { randomUUID } from "node:crypto"

import Database from "better-sqlite3"

import { instanceMetaSql, readInstanceMeta } from "./common-rows.js"

export const resolveServerIdentity = (filename: string): string => {
  const sqlite = new Database(filename)
  try {
    sqlite.exec(instanceMetaTableSql)
    const existing = readInstanceMeta(sqlite, "machine-id")
    if (existing !== undefined) return existing
    const id = randomUUID()
    sqlite.prepare(instanceMetaSql.insertMachineId).run(id)
    return id
  } finally {
    sqlite.close()
  }
}

const instanceMetaTableSql = `
      create table if not exists instance_meta (
        key text primary key,
        value text not null
      );
    `
