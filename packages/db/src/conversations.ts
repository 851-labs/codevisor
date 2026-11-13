import { randomUUID } from "node:crypto"

import type Database from "better-sqlite3"

import { nullable, rowReader, text } from "./row-reader.js"

export interface BotConversation {
  readonly conversationId: string
  readonly userParticipantId: string
  readonly botParticipantId: string
}

export const openBotConversation = (
  sqlite: Database.Database,
  bot: { readonly id: string; readonly serverId: string },
  createdAt: string
): BotConversation => {
  const conversation: BotConversation = {
    conversationId: randomUUID(),
    userParticipantId: randomUUID(),
    botParticipantId: randomUUID()
  }
  sqlite.prepare(conversationSql.insert).run(conversation.conversationId, bot.serverId, createdAt)
  sqlite
    .prepare(conversationSql.addUser)
    .run(conversation.userParticipantId, conversation.conversationId, createdAt)
  sqlite
    .prepare(conversationSql.addBot)
    .run(conversation.botParticipantId, conversation.conversationId, bot.id, createdAt)
  sqlite.prepare(conversationSql.setBotConversation).run(conversation.conversationId, bot.id)
  return conversation
}

export const botConversationOfChat = (
  sqlite: Database.Database,
  sessionId: string
): BotConversation | undefined => {
  const row = botConversationRows.maybe(sqlite.prepare(conversationSql.ofBotChat).get(sessionId))
  if (row === undefined || row.conversation_id === null) return undefined
  if (row.user_participant_id === null || row.bot_participant_id === null) return undefined
  return {
    conversationId: row.conversation_id,
    userParticipantId: row.user_participant_id,
    botParticipantId: row.bot_participant_id
  }
}

export const closeBotConversation = (sqlite: Database.Database, botId: string): void => {
  sqlite.prepare(conversationSql.deleteOfBot).run(botId)
}

const botConversationRows = rowReader({
  conversation_id: nullable(text),
  user_participant_id: nullable(text),
  bot_participant_id: nullable(text)
})

const conversationSql = {
  insert: "insert into conversations (id, server_id, created_at) values (?, ?, ?)",
  addUser: `insert into conversation_participants (id, conversation_id, kind, created_at)
      values (?, ?, 'user', ?)`,
  addBot: `insert into conversation_participants (id, conversation_id, kind, bot_id, created_at)
      values (?, ?, 'bot', ?, ?)`,
  setBotConversation: "update bots set conversation_id = ? where id = ?",
  ofBotChat: `select bots.conversation_id,
        (select id from conversation_participants
          where conversation_id = bots.conversation_id and kind = 'user') as user_participant_id,
        (select id from conversation_participants
          where conversation_id = bots.conversation_id and kind = 'bot' and bot_id = bots.id)
          as bot_participant_id
      from bots where bots.session_id = ?`,
  deleteOfBot: `delete from conversations where id in (
        select conversation_id from conversation_participants where bot_id = ?)`
}
