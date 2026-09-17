import { initialWorkspacePosition } from "@codevisor/api"

import type { Migration } from "./migration-types.js"

export const migrations47: ReadonlyArray<Migration> = [
  {
    id: 47,
    name: "shared workspace sidebar positions",
    sql: `
    alter table workspaces add column sidebar_position text not null default '';
    alter table workspaces add column sidebar_order_revision integer not null default 1;
    create index workspaces_sidebar_position on workspaces(sidebar_position);
  `,
    run(sqlite) {
      // Start fresh from creation order. Never import device-local preferences.
      const rows = sqlite.prepare("select id, created_at from workspaces").all() as {
        id: string
        created_at: string
      }[]
      const update = sqlite.prepare("update workspaces set sidebar_position = ? where id = ?")
      for (const row of rows)
        update.run(initialWorkspacePosition(Date.parse(row.created_at) || 0, row.id), row.id)
    }
  }
]
