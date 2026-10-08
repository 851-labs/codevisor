import type { Migration } from "./migration-types.js"

export const migrations60: ReadonlyArray<Migration> = [
  {
    id: 60,
    name: "owned workspaces and sidebar folders",
    // An orchestrating agent can own child workspaces (a subagent with its own
    // worktree). The child lists under its parent instead of the top level,
    // shows as a tab group in the parent's tab bar at `parent_tab_position`
    // (the same key space as the parent's pane positions), and archives with
    // it. `folder_id` files a top-level workspace into a sidebar folder.
    //
    // The session navigation trigger now also watches the orchestration
    // columns, so clients learn a chat's parent; dropping it lets
    // installNavigationJournal recreate it after the schema commit.
    sql: `
      alter table workspaces add column parent_workspace_id text;
      alter table workspaces add column parent_tab_position text not null default '';
      alter table workspaces add column group_collapsed integer not null default 0;
      alter table workspaces add column folder_id text;
      create index if not exists workspaces_parent_workspace_idx on workspaces(parent_workspace_id);
      drop trigger if exists navigation_sessions_update;
    `
  }
]
