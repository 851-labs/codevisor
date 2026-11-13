import { randomUUID } from "node:crypto"

import {
  isoTimestamp,
  type Thread,
  type ThreadMessage,
  type ThreadParticipant
} from "@codevisor/api"
import type Database from "better-sqlite3"
import type { Effect } from "effect"

import { attempt, type DatabaseError } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { integer, literal, nullable, rowReader, text } from "./row-reader.js"
import type { ServiceContext } from "./service-context.js"

export type ThreadParty =
  | { readonly kind: "bot"; readonly botId: string }
  | {
      readonly kind: "agent"
      readonly agentId: string
      readonly machineId: string
      readonly name?: string | undefined
    }
  | {
      readonly kind: "remoteBot"
      readonly botId: string
      readonly agentId: string
      readonly machineId: string
      readonly name: string
    }

export interface ThreadMessageRecord {
  readonly id?: string | undefined
  readonly text: string
  readonly createdAt?: string | undefined
}

export interface AppendedThreadMessage {
  readonly message: ThreadMessage
  readonly created: boolean
}

export interface ThreadMessagePage {
  readonly messages: ReadonlyArray<ThreadMessage>
  readonly hasMore: boolean
}

export interface ThreadsService {
  readonly openThread: (
    first: ThreadParty,
    second: ThreadParty,
    threadId?: string
  ) => Effect.Effect<Thread, DatabaseError>
  readonly findThread: (
    first: ThreadParty,
    second: ThreadParty
  ) => Effect.Effect<Thread | undefined, DatabaseError>
  readonly getThread: (threadId: string) => Effect.Effect<Thread | undefined, DatabaseError>
  readonly listThreads: (party: ThreadParty) => Effect.Effect<ReadonlyArray<Thread>, DatabaseError>
  readonly appendThreadMessage: (
    threadId: string,
    from: ThreadParty,
    record: ThreadMessageRecord
  ) => Effect.Effect<AppendedThreadMessage, DatabaseError>
  readonly listThreadMessages: (
    threadId: string,
    before: number | undefined,
    limit: number
  ) => Effect.Effect<ThreadMessagePage, DatabaseError>
}

export const makeThreadsService = ({ sqlite, config }: ServiceContext): ThreadsService => ({
  openThread: (first, second, threadId) =>
    attempt("openThread", () =>
      sqlite.transaction(() => {
        const existing = threadIdOf(sqlite, first, second)
        const parties = { first, second, threadId: threadId ?? randomUUID() }
        return knownThread(sqlite, existing ?? createThread(sqlite, config.serverId, parties))
      })()
    ),
  findThread: (first, second) =>
    attempt("findThread", () => {
      const threadId = threadIdOf(sqlite, first, second)
      return threadId === undefined ? undefined : knownThread(sqlite, threadId)
    }),
  getThread: (threadId) => attempt("getThread", () => readThread(sqlite, threadId)),
  listThreads: (party) =>
    attempt("listThreads", () =>
      threadIdRows
        .all(sqlite.prepare(threadSql.ofParty).all(partyKey(party)))
        .map((row) => knownThread(sqlite, row.id))
    ),
  appendThreadMessage: (threadId, from, record) =>
    attempt("appendThreadMessage", () =>
      sqlite.transaction(() => {
        const sender = participantRows.maybe(
          sqlite.prepare(threadSql.participant).get({ threadId, ...partyKey(from) })
        )
        if (sender === undefined) throw new Error(`Not in thread ${threadId}`)
        const id = record.id ?? randomUUID()
        const existing = messageRows.maybe(sqlite.prepare(threadSql.message).get(id))
        if (existing !== undefined) return { message: messageFromRow(existing), created: false }
        sqlite.prepare(threadSql.insertMessage).run({
          id,
          threadId,
          senderId: sender.id,
          text: record.text,
          createdAt: record.createdAt ?? isoTimestamp()
        })
        const row = messageRows.one(sqlite.prepare(threadSql.message).get(id))
        return { message: messageFromRow(row), created: true }
      })()
    ),
  listThreadMessages: (threadId, before, limit) =>
    attempt("listThreadMessages", () => {
      const rows = messageRows.all(
        sqlite
          .prepare(threadSql.messagesBefore)
          .all(threadId, before ?? Number.MAX_SAFE_INTEGER, limit + 1)
      )
      return {
        messages: rows.slice(0, limit).toReversed().map(messageFromRow),
        hasMore: rows.length > limit
      }
    })
})

interface NewThread {
  readonly first: ThreadParty
  readonly second: ThreadParty
  readonly threadId: string
}

const createThread = (sqlite: Database.Database, serverId: string, thread: NewThread): string => {
  const { threadId } = thread
  const createdAt = isoTimestamp()
  sqlite.prepare(threadSql.insert).run(threadId, serverId, createdAt)
  for (const party of [thread.first, thread.second]) {
    sqlite
      .prepare(threadSql.addParticipant)
      .run({ id: randomUUID(), threadId, createdAt, ...partyColumns(party) })
  }
  return threadId
}

const threadIdOf = (
  sqlite: Database.Database,
  first: ThreadParty,
  second: ThreadParty
): string | undefined => {
  const a = partyKey(first)
  const b = partyKey(second)
  return threadIdRows.maybe(
    sqlite.prepare(threadSql.between).get({
      aKind: a.kind,
      aBot: a.botId,
      aAgent: a.agentId,
      aMachine: a.machineId,
      bKind: b.kind,
      bBot: b.botId,
      bAgent: b.agentId,
      bMachine: b.machineId
    })
  )?.id
}

const knownThread = (sqlite: Database.Database, threadId: string): Thread =>
  threadOf(sqlite, threadId, participantsOf(sqlite, threadId))

const readThread = (sqlite: Database.Database, threadId: string): Thread | undefined => {
  const rows = participantsOf(sqlite, threadId)
  if (rows.length === 0 || rows.some((row) => row.kind === "user")) return undefined
  return threadOf(sqlite, threadId, rows)
}

const participantsOf = (sqlite: Database.Database, threadId: string) =>
  participantRows.all(sqlite.prepare(threadSql.participants).all(threadId))

const threadOf = (
  sqlite: Database.Database,
  threadId: string,
  rows: ReadonlyArray<ParticipantFields>
): Thread => {
  const last = messageRows.maybe(sqlite.prepare(threadSql.lastMessage).get(threadId))
  return {
    threadId,
    participants: rows.map(participantFromRow),
    ...(last === undefined ? {} : { lastMessage: messageFromRow(last) })
  }
}

interface PartyKey {
  readonly kind: "bot" | "agent"
  readonly botId: string
  readonly agentId: string
  readonly machineId: string
}

const partyKey = (party: ThreadParty): PartyKey =>
  party.kind === "bot"
    ? { kind: "bot", botId: canonicalUuid(party.botId), agentId: "", machineId: "" }
    : {
        kind: party.kind === "agent" ? "agent" : "bot",
        botId: "",
        agentId: canonicalUuid(party.agentId),
        machineId: party.machineId
      }

const partyColumns = (party: ThreadParty) => {
  const key = partyKey(party)
  const isLocalBot = party.kind === "bot"
  return {
    kind: key.kind,
    botId: isLocalBot ? key.botId : null,
    agentId: isLocalBot ? null : key.agentId,
    machineId: isLocalBot ? null : key.machineId,
    remoteBotId: party.kind === "remoteBot" ? canonicalUuid(party.botId) : null,
    name: party.kind === "bot" ? null : (party.name ?? null)
  }
}

const threadIdRows = rowReader({ id: text })

const participantColumns = {
  kind: literal("user", "bot", "agent"),
  bot_id: nullable(text),
  agent_id: nullable(text),
  agent_machine_id: nullable(text),
  remote_bot_id: nullable(text),
  chat_id: text,
  name: text
}

const participantRows = rowReader({ id: text, ...participantColumns })

const messageRows = rowReader({
  id: text,
  conversation_id: text,
  sequence: integer,
  text: text,
  created_at: text,
  ...participantColumns
})

type ParticipantFields = Pick<
  ReturnType<typeof participantRows.one>,
  "kind" | "bot_id" | "agent_machine_id" | "remote_bot_id" | "chat_id" | "name"
>

const participantFromRow = (row: ParticipantFields): ThreadParticipant => ({
  kind: row.kind === "bot" ? "bot" : "agent",
  name: row.name,
  agentId: row.chat_id,
  ...botIdOf(row),
  ...(row.agent_machine_id === null ? {} : { machineId: row.agent_machine_id })
})

const botIdOf = (row: ParticipantFields): { readonly botId?: string } => {
  const botId = row.bot_id ?? row.remote_bot_id
  return botId === null ? {} : { botId }
}

const messageFromRow = (row: ReturnType<typeof messageRows.one>): ThreadMessage => ({
  id: row.id,
  threadId: row.conversation_id,
  sequence: row.sequence,
  from: participantFromRow(row),
  text: row.text,
  createdAt: row.created_at
})

const participantSelect = `p.kind, p.bot_id, p.agent_id, p.agent_machine_id, p.remote_bot_id,
      coalesce(p.agent_id, (select session_id from bots where bots.id = p.bot_id), '') as chat_id,
      coalesce((select name from bots where bots.id = p.bot_id), p.name,
        (select title from sessions where sessions.id = p.agent_id), '') as name`

const matches = (side: "a" | "b") => `exists (
        select 1 from conversation_participants p
          where p.conversation_id = c.id and p.kind = @${side}Kind
            and coalesce(p.bot_id, '') = @${side}Bot
            and coalesce(p.agent_id, '') = @${side}Agent
            and coalesce(p.agent_machine_id, '') = @${side}Machine)`

const messageSelect = `select m.id, m.conversation_id, m.sequence, m.text, m.created_at, ${participantSelect}
      from conversation_messages m
      join conversation_participants p on p.id = m.sender_id`

const threadSql = {
  insert: "insert into conversations (id, server_id, created_at) values (?, ?, ?)",
  addParticipant: `insert into conversation_participants (
        id, conversation_id, kind, bot_id, agent_id, agent_machine_id, remote_bot_id, name, created_at
      ) values (
        @id, @threadId, @kind, @botId, @agentId, @machineId, @remoteBotId, @name, @createdAt
      )`,
  between: `select c.id from conversations c
      where (select count(*) from conversation_participants p where p.conversation_id = c.id) = 2
        and ${matches("a")} and ${matches("b")}
      order by c.created_at, c.id limit 1`,
  participants: `select p.id, ${participantSelect} from conversation_participants p
      where p.conversation_id = ? order by p.created_at, p.rowid`,
  participant: `select p.id, ${participantSelect} from conversation_participants p
      where p.conversation_id = @threadId and p.kind = @kind
        and coalesce(p.bot_id, '') = @botId and coalesce(p.agent_id, '') = @agentId
        and coalesce(p.agent_machine_id, '') = @machineId`,
  ofParty: `select c.id from conversations c
      join conversation_participants p on p.conversation_id = c.id
      where p.kind = @kind and coalesce(p.bot_id, '') = @botId
        and coalesce(p.agent_id, '') = @agentId and coalesce(p.agent_machine_id, '') = @machineId
        and not exists (select 1 from conversation_participants u
          where u.conversation_id = c.id and u.kind = 'user')
      order by (select max(m.rowid) from conversation_messages m
        where m.conversation_id = c.id) desc nulls last, c.rowid desc`,
  insertMessage: `insert into conversation_messages (
        id, conversation_id, sequence, sender_id, text, created_at
      ) values (@id, @threadId, (
        select coalesce(max(sequence), 0) + 1 from conversation_messages
          where conversation_id = @threadId
      ), @senderId, @text, @createdAt)`,
  message: `${messageSelect} where m.id = ?`,
  lastMessage: `${messageSelect} where m.conversation_id = ? order by m.sequence desc limit 1`,
  messagesBefore: `${messageSelect} where m.conversation_id = ? and m.sequence < ?
      order by m.sequence desc limit ?`
}
