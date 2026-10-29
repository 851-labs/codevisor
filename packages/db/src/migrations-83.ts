import type { Migration } from "./migration-types.js"

export const migrations83: ReadonlyArray<Migration> = [
  {
    id: 83,
    name: "fresh agent sessions",
    sql: `
      alter table sessions add column fresh_agent_session_id text;
      update sessions set fresh_agent_session_id = agent_session_id
        where origin in ('codevisor', 'herdman')
          and coalesce(agent_session_id, '') <> ''
          and not exists (select 1 from chat_items where chat_items.session_id = sessions.id);
    `
  }
]
