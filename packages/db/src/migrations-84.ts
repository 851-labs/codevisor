import type { Migration } from "./migration-types.js"

export const migrations84: ReadonlyArray<Migration> = [
  {
    id: 84,
    name: "workspace detached head",
    sql: `
      alter table workspaces add column git_detached_head text;
    `
  }
]
