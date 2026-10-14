import type { Migration } from "./migration-types.js"

export const migrations56: ReadonlyArray<Migration> = [
  {
    id: 56,
    name: "terminal pane live titles and activity",
    sql: `
      alter table workspace_panes add column live_title text;
      alter table workspace_panes add column terminal_activity text
        check (terminal_activity in ('working', 'idle'));
    `
  }
]
