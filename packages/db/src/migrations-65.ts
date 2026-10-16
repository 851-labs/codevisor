import type { Migration } from "./migration-types.js"

export const migrations65: ReadonlyArray<Migration> = [
  {
    id: 65,
    name: "bots",
    sql: `
      create table bots (
        id text primary key,
        server_id text not null,
        name text not null,
        symbol_name text not null,
        slug text not null unique,
        project_id text not null references projects(id),
        session_id text not null references sessions(id),
        workspace_id text not null references workspaces(id),
        created_at text not null,
        updated_at text
      );
      create table bot_projects (
        bot_id text not null references bots(id) on delete cascade,
        project_id text not null references projects(id),
        folder_name text not null,
        branch text not null,
        position integer not null,
        primary key (bot_id, project_id),
        unique (bot_id, folder_name)
      );
      create index bot_projects_project on bot_projects(project_id);
    `
  }
]
