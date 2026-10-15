import { initialPanePosition } from "@codevisor/api"

import type { Migration } from "./migration-types.js"
import { rowReader, text } from "./row-reader.js"

const createdRows = rowReader({ id: text, created_at: text })

export const migrations55: ReadonlyArray<Migration> = [
  {
    id: 55,
    name: "shared tab order",
    sql: `
      alter table workspace_panes add column position text not null default '';
    `,
    run(sqlite) {
      const rows = createdRows.all(
        sqlite.prepare("select id, created_at from workspace_panes").all()
      )
      const update = sqlite.prepare("update workspace_panes set position = ? where id = ?")
      for (const row of rows)
        update.run(initialPanePosition(Date.parse(row.created_at) || 0, row.id), row.id)
    }
  }
]
