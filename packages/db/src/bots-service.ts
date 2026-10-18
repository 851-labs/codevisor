import type { Bot } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"

import { botProjectRows, botRows, type BotRow, type BotsService } from "./bot-rows.js"
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
      projects: botProjectRows
        .all(
          sqlite
            .prepare("select * from bot_projects where bot_id = ? order by position asc")
            .all(row.id)
        )
        .map((project) => ({
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
    const row = botRows.maybe(
      sqlite.prepare(`${botSelect} where bots.id = ?`).get(canonicalUuid(id))
    )
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
            .prepare(
              `insert into bots (
                id, server_id, name, symbol_name, slug, project_id, session_id, workspace_id,
                conversational, created_at
              ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`
            )
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
          const insertProject = sqlite.prepare(
            `insert into bot_projects (bot_id, project_id, folder_name, branch, position)
             values (?, ?, ?, ?, ?)`
          )
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
    listBots: attempt("listBots", () =>
      botRows
        .all(sqlite.prepare(`${botSelect} order by bots.created_at asc, bots.id asc`).all())
        .map(botFromRow)
    ),
    getBot: (id) => attempt("getBot", () => findBot(id)),
    updateBot: (id, record) =>
      attempt("updateBot", () => {
        const current = requireBot(id)
        sqlite
          .prepare("update bots set name = ?, symbol_name = ?, updated_at = ? where id = ?")
          .run(
            record.name ?? current.name,
            record.symbolName ?? current.symbolName,
            isoTimestamp(),
            current.id
          )
        return requireBot(current.id)
      }),
    deleteBot: (id) =>
      attempt("deleteBot", () => {
        sqlite.prepare("delete from bots where id = ?").run(canonicalUuid(id))
      }),
    findBotOwning: (query) =>
      attempt("findBotOwning", () => {
        const projectId = query.projectId === undefined ? null : canonicalUuid(query.projectId)
        const row = botRows.maybe(
          sqlite
            .prepare(
              `${botSelect}
               where bots.project_id = @projectId collate nocase
                 or bots.workspace_id = @workspaceId collate nocase
                 or bots.session_id = @sessionId collate nocase
                 or exists (
                   select 1 from bot_projects
                   where bot_projects.bot_id = bots.id and bot_projects.project_id = @projectId collate nocase
                 )
               order by bots.created_at asc limit 1`
            )
            .get({
              projectId,
              workspaceId:
                query.workspaceId === undefined ? null : canonicalUuid(query.workspaceId),
              sessionId: query.sessionId === undefined ? null : canonicalUuid(query.sessionId)
            })
        )
        return row === undefined ? undefined : botFromRow(row)
      }),
    listBotWorkspaces: (botId) =>
      attempt("listBotWorkspaces", () =>
        workspaceRows
          .all(
            sqlite
              .prepare(
                `select * from workspaces where bot_id = ? and is_archived = 0
                 order by sidebar_position, id`
              )
              .all(canonicalUuid(botId))
          )
          .map(workspaceFromRow)
      )
  }
}
