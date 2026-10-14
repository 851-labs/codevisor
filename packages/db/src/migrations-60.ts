import type { Migration } from "./migration-types.js"

export const migrations60: ReadonlyArray<Migration> = [
  {
    id: 60,
    name: "retire agent terminal panes",
    sql: `
      delete from workspace_panes
      where pane_type = 'terminal' and json_extract(metadata, '$.attachOnly') = 1;
    `
  }
]
