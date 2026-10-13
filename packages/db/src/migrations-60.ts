import type { Migration } from "./migration-types.js"

export const migrations60: ReadonlyArray<Migration> = [
  {
    id: 60,
    name: "retire agent terminal panes",
    // Agent background commands no longer get terminal tabs. Clients kept
    // the ones they made hidden (an attach-only terminal owned by a chat);
    // nothing shows or removes them now.
    sql: `
      delete from workspace_panes
      where pane_type = 'terminal' and json_extract(metadata, '$.attachOnly') = 1;
    `
  }
]
