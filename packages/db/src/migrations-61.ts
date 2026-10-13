import type { Migration } from "./migration-types.js"

export const migrations61: ReadonlyArray<Migration> = [
  {
    id: 61,
    name: "terminal pane program status",
    // Programs that speak the Program Status Protocol (OSC 7501) report
    // three more states than a title shows. SQLite can't change a column's
    // check, so the column is recreated; no value outlives a boot anyway
    // (the server clears them all at startup).
    sql: `
      alter table workspace_panes drop column terminal_activity;
      alter table workspace_panes add column terminal_activity text
        check (terminal_activity in ('working', 'idle', 'done', 'blocked', 'error'));
    `
  }
]
