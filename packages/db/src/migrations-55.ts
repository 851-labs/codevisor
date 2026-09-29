import { initialPanePosition } from "@codevisor/api"

import type { Migration } from "./migration-types.js"

export const migrations55: ReadonlyArray<Migration> = [
  {
    id: 55,
    name: "shared tab order",
    // Panes gain a shared tab order key; existing tabs start in creation
    // order.
    sql: `
      alter table workspace_panes add column position text not null default '';
    `,
    run(sqlite) {
      const rows = sqlite.prepare("select id, created_at from workspace_panes").all() as {
        id: string
        created_at: string
      }[]
      const update = sqlite.prepare("update workspace_panes set position = ? where id = ?")
      for (const row of rows)
        update.run(initialPanePosition(Date.parse(row.created_at) || 0, row.id), row.id)
    }
  }
]
