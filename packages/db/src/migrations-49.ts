import type { Migration } from "./migration-types.js"

export const migrations49: ReadonlyArray<Migration> = [
  {
    id: 49,
    name: "retire placeholder panes",
    // "New tab" is no longer stored: a workspace may simply have no panes and
    // every client renders that state with its own local empty page.
    sql: `
      delete from workspace_panes where provider_id = 'codevisor' and pane_type = 'new-tab';
    `
  }
]
