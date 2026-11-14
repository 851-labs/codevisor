import type { Migration } from "./migration-types.js"

export const migrations111: ReadonlyArray<Migration> = [
  {
    id: 111,
    name: "a bot's sub-agents made before sub-agents lost their workspace lose theirs too",
    sql: `
      create temp table bot_agent_workspaces as
        with recursive bot_agents(id) as (
          select sessions.id from sessions
            where sessions.is_detached = 0
              and sessions.created_by_agent_id in (select session_id from bots)
          union
          select sessions.id from sessions
            join bot_agents on sessions.created_by_agent_id = bot_agents.id
            where sessions.is_detached = 0
        )
        select workspaces.id from workspaces
          where workspaces.main_session_id in (select id from bot_agents)
            and workspaces.id not in (select workspace_id from bots)
            and not exists (
              select 1 from sessions
                where sessions.workspace_id = workspaces.id
                  and sessions.id not in (select id from bot_agents)
            );
      delete from workspace_panes
        where workspace_id in (select id from bot_agent_workspaces);
      update sessions set workspace_id = null
        where workspace_id in (select id from bot_agent_workspaces);
      delete from workspaces where id in (select id from bot_agent_workspaces);
      drop table bot_agent_workspaces;
    `
  }
]
