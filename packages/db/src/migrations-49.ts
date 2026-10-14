import type { Migration } from "./migration-types.js"

export const migrations49: ReadonlyArray<Migration> = [
  {
    id: 49,
    name: "retire placeholder panes",
    sql: `
      delete from workspace_panes where provider_id = 'codevisor' and pane_type = 'new-tab';
    `
  }
]
