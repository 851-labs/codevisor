import type Database from "better-sqlite3"

import { openBotConversation } from "./conversations.js"
import type { Migration } from "./migration-types.js"
import { rowReader, text } from "./row-reader.js"

const botRows = rowReader({ id: text, server_id: text, session_id: text, created_at: text })

const moveBotMessages = (sqlite: Database.Database): void => {
  for (const bot of botRows.all(sqlite.prepare(backfillSql.bots).all())) {
    const conversation = openBotConversation(
      sqlite,
      { id: bot.id, serverId: bot.server_id },
      bot.created_at
    )
    sqlite.prepare(backfillSql.moveMessages).run({
      conversationId: conversation.conversationId,
      userId: conversation.userParticipantId,
      botId: conversation.botParticipantId,
      sessionId: bot.session_id
    })
  }
}

export const migrations104: ReadonlyArray<Migration> = [
  {
    id: 104,
    name: "a bot's messages belong to a conversation that records who is in it",
    sql: `
      create table conversations (
        id text primary key,
        server_id text not null,
        created_at text not null
      );
      create table conversation_participants (
        id text primary key,
        conversation_id text not null references conversations(id) on delete cascade,
        kind text not null check(kind in ('user', 'bot', 'agent')),
        bot_id text references bots(id) on delete cascade,
        agent_id text,
        agent_machine_id text,
        created_at text not null
      );
      create index conversation_participants_conversation_idx
        on conversation_participants(conversation_id);
      create index conversation_participants_bot_idx on conversation_participants(bot_id);
      create table conversation_messages (
        id text primary key,
        conversation_id text not null references conversations(id) on delete cascade,
        sequence integer not null,
        sender_id text references conversation_participants(id) on delete set null,
        text text not null,
        attachments text,
        created_at text not null
      );
      create unique index conversation_messages_sequence_idx
        on conversation_messages(conversation_id, sequence);
      alter table bots add column conversation_id text references conversations(id) on delete set null;
      create index bots_session_idx on bots(session_id);
    `,
    run: (sqlite) => {
      moveBotMessages(sqlite)
      sqlite.exec("drop table bot_messages")
    }
  }
]

const backfillSql = {
  bots: "select id, server_id, session_id, created_at from bots order by created_at, id",
  moveMessages: `insert into conversation_messages (
        id, conversation_id, sequence, sender_id, text, attachments, created_at
      )
      select id, @conversationId, sequence,
        case sender when 'user' then @userId when 'notice' then null else @botId end,
        text, attachments, created_at
      from bot_messages where session_id = @sessionId`
}
