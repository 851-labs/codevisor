import type { Migration } from "./migration-types.js"

export const migrations64: ReadonlyArray<Migration> = [
  {
    id: 64,
    name: "workspace git state",
    sql: `
      alter table workspaces add column git_branch text;
      alter table workspaces add column git_pull_request text;
      alter table workspaces add column git_known integer not null default 0;
    `
  }
]
