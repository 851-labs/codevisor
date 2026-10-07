import type { Migration } from "./migration-types.js"

export const migrations59: ReadonlyArray<Migration> = [
  {
    id: 59,
    name: "project default run location",
    // The project directory vs. new worktree choice new chats start with.
    // Stored on the project (not per client) so every client and every
    // machine holding the repository restores the same choice.
    sql: `
      alter table projects add column default_run_location text;
    `
  }
]
