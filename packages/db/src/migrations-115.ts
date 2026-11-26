import type { Migration } from "./migration-types.js"

const harnesslessChats = `
  select id from sessions
  where harness_id = ''
    and not exists (select 1 from chat_items where chat_items.session_id = sessions.id)
    and not exists (select 1 from conversation_items where conversation_items.session_id = sessions.id)
    and not exists (select 1 from transcript_items where transcript_items.session_id = sessions.id)
    and not exists (select 1 from bots where bots.session_id = sessions.id)
`

export const migrations115: ReadonlyArray<Migration> = [
  {
    id: 115,
    name: "every chat has a harness: drop empty chats without one, and give the rest Claude Code",
    sql: `
      delete from workspace_panes
        where resource_kind = 'session' and resource_id in (${harnesslessChats});
      delete from sessions where id in (${harnesslessChats});
      update sessions set harness_id = 'claude-code' where harness_id = '';
    `
  }
]
