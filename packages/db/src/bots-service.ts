import type { Bot } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"

import {
  botProjectRows,
  botRows,
  type BotOwnerQuery,
  type BotRow,
  type BotsService
} from "./bot-rows.js"
import { attempt } from "./errors.js"
import { canonicalUuid } from "./ids.js"
import { botPath } from "./paths.js"
import { workspaceFromRow } from "./row-mappers.js"
import { workspaceRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"

const botSelect = `
  select bots.*, sessions.harness_id as harness_id
  from bots join sessions on sessions.id = bots.session_id
`

export const makeBotsService = (
  context: ServiceContext
): Omit<BotsService, "appendBotMessage" | "listBotMessages"> => {
  const { sqlite, config } = context

  const botFromRow = (row: BotRow): Bot => {
    const rootPath = botPath(row.slug)
    return {
      id: row.id,
      serverId: row.server_id,
      name: row.name,
      symbolName: row.symbol_name,
      harnessId: row.harness_id,
      projectId: row.project_id,
      sessionId: row.session_id,
      workspaceId: row.workspace_id,
      rootPath,
      projects: botProjects(sqlite, row.id).map((project) => ({
        projectId: project.project_id,
        folderName: project.folder_name,
        branch: project.branch,
        path: `${rootPath}/${project.folder_name}`
      })),
      conversational: row.conversational === 1,
      createdAt: row.created_at,
      ...(row.updated_at === null ? {} : { updatedAt: row.updated_at })
    }
  }

  const findBot = (id: string): Bot | undefined => {
    const row = botRow(sqlite, id)
    return row === undefined ? undefined : botFromRow(row)
  }

  const requireBot = (id: string): Bot => {
    const bot = findBot(id)
    if (bot === undefined) throw new Error(`Bot not found: ${id}`)
    return bot
  }

  return {
    createBot: (record) =>
      attempt("createBot", () => {
        const id = canonicalUuid(record.id)
        sqlite.transaction(() => {
          sqlite
            .prepare(botSql.insert)
            .run(
              id,
              config.serverId,
              record.name,
              record.symbolName,
              record.slug,
              canonicalUuid(record.projectId),
              canonicalUuid(record.sessionId),
              canonicalUuid(record.workspaceId),
              record.conversational === true ? 1 : 0,
              isoTimestamp()
            )
          const insertProject = sqlite.prepare(botProjectSql.insert)
          record.projects.forEach((project, position) => {
            insertProject.run(
              id,
              canonicalUuid(project.projectId),
              project.folderName,
              project.branch,
              position
            )
          })
        })()
        return requireBot(id)
      }),
    listBots: attempt("listBots", () => botsOldestFirst(sqlite).map(botFromRow)),
    getBot: (id) => attempt("getBot", () => findBot(id)),
    updateBot: (id, record) =>
      attempt("updateBot", () => {
        const current = requireBot(id)
        sqlite
          .prepare(botSql.update)
          .run(
            record.name ?? current.name,
            record.symbolName ?? current.symbolName,
            isoTimestamp(),
            current.id
          )
        return requireBot(current.id)
      }),
    addBotProject: (id, record) =>
      attempt("addBotProject", () => {
        const current = requireBot(id)
        sqlite
          .prepare(botProjectSql.append)
          .run(
            current.id,
            canonicalUuid(record.projectId),
            record.folderName,
            record.branch,
            current.id
          )
        touchBot(sqlite, current.id)
        return requireBot(current.id)
      }),
    removeBotProject: (id, projectId) =>
      attempt("removeBotProject", () => {
        const current = requireBot(id)
        sqlite.prepare(botProjectSql.remove).run(current.id, canonicalUuid(projectId))
        touchBot(sqlite, current.id)
        return requireBot(current.id)
      }),
    deleteBot: (id) =>
      attempt("deleteBot", () => {
        sqlite.prepare(botSql.delete).run(canonicalUuid(id))
      }),
    findBotOwning: (query) =>
      attempt("findBotOwning", () => {
        const projectId = query.projectId === undefined ? null : canonicalUuid(query.projectId)
        const row = owningBotRow(sqlite, projectId, query)
        return row === undefined ? undefined : botFromRow(row)
      }),
    listBotWorkspaces: (botId) =>
      attempt("listBotWorkspaces", () => botWorkspaces(sqlite, botId).map(workspaceFromRow))
  }
}

const botRow = (sqlite: ServiceContext["sqlite"], id: string) =>
  botRows.maybe(sqlite.prepare(botSql.byId).get(canonicalUuid(id)))

const owningBotRow = (
  sqlite: ServiceContext["sqlite"],
  projectId: string | null,
  query: BotOwnerQuery
) =>
  botRows.maybe(
    sqlite.prepare(botSql.owning).get({
      projectId,
      workspaceId: query.workspaceId === undefined ? null : canonicalUuid(query.workspaceId),
      sessionId: query.sessionId === undefined ? null : canonicalUuid(query.sessionId)
    })
  )

const botsOldestFirst = (sqlite: ServiceContext["sqlite"]) =>
  botRows.all(sqlite.prepare(botSql.list).all())

const botProjects = (sqlite: ServiceContext["sqlite"], botId: string) =>
  botProjectRows.all(sqlite.prepare(botProjectSql.byBot).all(botId))

const botWorkspaces = (sqlite: ServiceContext["sqlite"], botId: string) =>
  workspaceRows.all(sqlite.prepare(botSql.workspaces).all(canonicalUuid(botId)))

const touchBot = (sqlite: ServiceContext["sqlite"], id: string): void => {
  sqlite.prepare(botSql.touch).run(isoTimestamp(), id)
}

const botSql = {
  byId: `${botSelect} where bots.id = ?`,
  list: `${botSelect} order by bots.created_at asc, bots.id asc`,
  insert: `insert into bots (
                id, server_id, name, symbol_name, slug, project_id, session_id, workspace_id,
                conversational, created_at
              ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  update: "update bots set name = ?, symbol_name = ?, updated_at = ? where id = ?",
  touch: "update bots set updated_at = ? where id = ?",
  delete: "delete from bots where id = ?",
  owning: `${botSelect}
               where bots.project_id = @projectId collate nocase
                 or bots.workspace_id = @workspaceId collate nocase
                 or bots.session_id = @sessionId collate nocase
                 or exists (
                   select 1 from bot_projects
                   where bot_projects.bot_id = bots.id and bot_projects.project_id = @projectId collate nocase
                 )
               order by bots.created_at asc limit 1`,
  workspaces: `select * from workspaces where bot_id = ? and is_archived = 0
                 order by sidebar_position, id`
}

const botProjectSql = {
  byBot: "select * from bot_projects where bot_id = ? order by position asc",
  insert: `insert into bot_projects (bot_id, project_id, folder_name, branch, position)
             values (?, ?, ?, ?, ?)`,
  append: `insert into bot_projects (bot_id, project_id, folder_name, branch, position)
             select ?, ?, ?, ?, coalesce(max(position), -1) + 1 from bot_projects where bot_id = ?`,
  remove: "delete from bot_projects where bot_id = ? and project_id = ? collate nocase"
}
