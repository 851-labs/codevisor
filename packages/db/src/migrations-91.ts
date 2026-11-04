import type { Migration } from "./migration-types.js"

export const migrations91: ReadonlyArray<Migration> = [
  {
    id: 91,
    name: "chat titles leaked from the interrupted-step note",
    sql: `
      update sessions set title = coalesce((
        select case
          when length(prompt) > 200 then rtrim(substr(prompt, 1, 200)) || '…'
          else prompt
        end
        from (
          select trim(replace(replace(parts.text, char(13), ' '), char(10), ' ')) as prompt
          from chat_items items
          join chat_parts parts on parts.item_id = items.id and parts.kind = 'text'
          where items.session_id = sessions.id
            and items.role = 'user'
            and coalesce(items.origin, '') <> 'event'
            and trim(coalesce(parts.text, '')) <> ''
          order by items.position desc
          limit 1
        )
      ), 'New Chat')
      where title_is_user_set = 0
        and title like '[Your previous step was interrupted%';
    `
  }
]
