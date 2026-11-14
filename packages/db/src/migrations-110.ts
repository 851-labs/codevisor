import type { Migration } from "./migration-types.js"

export const migrations110: ReadonlyArray<Migration> = [
  {
    id: 110,
    name: "workspaces and chats keep their folder, branch and worktree on the checkout only",
    sql: `
      drop trigger if exists navigation_sessions_update;
      alter table workspaces drop column root_directory;
      alter table workspaces drop column git_branch;
      alter table workspaces drop column git_detached_head;
      alter table workspaces drop column git_pull_request;
      alter table workspaces drop column git_known;
      alter table sessions drop column worktree_name;
    `
  }
]
