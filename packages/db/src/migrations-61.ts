import type { Migration } from "./migration-types.js"

export const migrations61: ReadonlyArray<Migration> = [
  {
    id: 61,
    name: "terminal pane program status",
    sql: `
      alter table workspace_panes drop column terminal_activity;
      alter table workspace_panes add column terminal_activity text
        check (terminal_activity in ('working', 'idle', 'done', 'blocked', 'error'));
    `
  }
]
