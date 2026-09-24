import type Database from "better-sqlite3"

/** Invalidation and the metadata mutation commit together. A crash between a
 * route's write and publish cannot create an invisible navigation change. */
export const installNavigationJournal = (db: Database.Database): void => {
  const tables: Record<string, readonly string[] | undefined> = {
    projects: undefined,
    project_locations: undefined,
    workspaces: undefined,
    workspace_panes: undefined,
    session_attention: [
      "attention_revision",
      "turn_active",
      "runtime_state",
      "current_mode_id",
      "pending_plan_approval",
      "errored"
    ],
    session_read_state: ["last_seen_sequence", "manually_unread"],
    sessions: [
      "title",
      "agent_session_id",
      "harness_id",
      "harness_account_id",
      "workspace_id",
      "worktree_name",
      "sidebar_state",
      "config_selections"
    ]
  }
  for (const [table, columns] of Object.entries(tables)) {
    for (const operation of ["insert", "update", "delete"] as const) {
      const record = operation === "delete" ? "old" : "new"
      const condition =
        operation === "update" && columns !== undefined
          ? `when ${columns.map((column) => `old.${column} is not new.${column}`).join(" or ")}`
          : ""
      db.exec(`create trigger if not exists navigation_${table}_${operation} after ${operation} on ${table} ${condition}
        begin
          insert into events (server_id, kind, subject_id, created_at, payload)
            values (coalesce((select value from instance_meta where key = 'adopted-server-id'), 'local'),
              'navigation.changed', ${record}.${table.startsWith("session_") ? "session_id" : "id"}, strftime('%Y-%m-%dT%H:%M:%fZ', 'now'), json_object('table', '${table}'${table === "project_locations" ? `, 'projectId', ${record}.project_id` : ""}));
          insert into sync_watermarks (subject_id, floor) values ('global', max(0, last_insert_rowid() - 2048))
            on conflict(subject_id) do update set floor = max(floor, excluded.floor);
          delete from events where id <= (select floor from sync_watermarks where subject_id = 'global');
        end;`)
    }
  }
}
