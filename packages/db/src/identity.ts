import { randomUUID } from "node:crypto"

import Database from "better-sqlite3"

export const resolveServerIdentity = (filename: string): string => {
  const sqlite = new Database(filename)
  try {
    sqlite.exec(`
      create table if not exists instance_meta (
        key text primary key,
        value text not null
      );
    `)
    const row = sqlite.prepare("select value from instance_meta where key = 'machine-id'").get() as
      | { readonly value: string }
      | undefined
    if (row !== undefined) return row.value
    const id = randomUUID()
    sqlite.prepare("insert into instance_meta (key, value) values ('machine-id', ?)").run(id)
    return id
  } finally {
    sqlite.close()
  }
}
