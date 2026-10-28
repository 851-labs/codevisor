import type { Migration } from "./migration-types.js"

export const migrations81: ReadonlyArray<Migration> = [
  {
    id: 81,
    name: "drop usage limit bot notices",
    sql: `
      delete from bot_messages
      where sender = 'notice'
        and exists (
          select 1 from chat_items
          where chat_items.session_id = bot_messages.session_id
            and chat_items.stop_kind = 'usageLimit'
            and chat_items.stop_detail = bot_messages.text
        );
    `
  }
]
