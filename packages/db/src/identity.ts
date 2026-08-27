import Database from "better-sqlite3"
import { randomUUID } from "node:crypto"

/// Reads (or mints) the database's persisted machine identity before the full
/// service opens. Remote servers derive their server id from this so a fleet
/// never sees two machines colliding on the default "local" id — the value is
/// the same `instance_meta` row `getOrCreateInstanceId` serves later, created
/// here with the identical shape migrations use.
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
