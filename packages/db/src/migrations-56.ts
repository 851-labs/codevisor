import type { Migration } from "./migration-types.js"

export const migrations56: ReadonlyArray<Migration> = [
  {
    id: 56,
    name: "terminal pane live titles and activity",
    // What runs in a terminal pane, as the server's own copy of its screen
    // last settled on it: the title its program set (OSC 0/2) and what the
    // agent there says it is doing (from the title's leading glyph).
    // Server-owned: client pane writes never carry them, so they live beside
    // the client-authored `title`.
    sql: `
      alter table workspace_panes add column live_title text;
      alter table workspace_panes add column terminal_activity text
        check (terminal_activity in ('working', 'idle'));
    `
  }
]
