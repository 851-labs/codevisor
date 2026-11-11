import type { Bot, BotMascot, Workspace } from "@codevisor/api"
import { isoTimestamp } from "@codevisor/api"

import {
  botProjectRows,
  botRows,
  type BotOwnerQuery,
  type BotRow,
  type BotsService
} from "./bot-rows.js"
import { attempt } from "./errors.js"
import { sessionConfigSelectionsFromRaw } from "./event-payloads.js"
import { canonicalUuid } from "./ids.js"
import { botPath } from "./paths.js"
import { workspaceFromRow } from "./row-mappers.js"
import { workspaceRows } from "./rows.js"
import type { ServiceContext } from "./service-context.js"
import type { WorkspaceRow } from "./workspace-rows.js"
import type { BotLink, RemoteBotLink } from "./workspace-service-types.js"

const botSelect = `
  select bots.*, sessions.harness_id as harness_id,
    sessions.config_selections as config_selections
  from bots join sessions on sessions.id = bots.session_id
`

export const makeBotsService = (
  context: ServiceContext
): Omit<BotsService, "appendBotMessage" | "listBotMessages"> => {
  const { sqlite, config } = context

  const botFromRow = (row: BotRow): Bot => {
    const rootPath = botPath(row.slug)
    const configSelections = sessionConfigSelectionsFromRaw(row.config_selections)
    return {
      id: row.id,
      serverId: row.server_id,
      name: row.name,
      symbolName: row.symbol_name,
      mascot: mascotFromRow(row),
      harnessId: row.harness_id,
      ...(Object.keys(configSelections).length === 0 ? {} : { configSelections }),
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
      isArchived: row.archived_at !== null,
      createdAt: row.created_at,
      ...(row.updated_at === null ? {} : { updatedAt: row.updated_at })
    }
  }

  const findBot = (id: string): Bot | undefined => {
    const row = botRow(sqlite, id)
    if (row === undefined) return undefined
    return botFromRow(row)
  }

  const requireBotRow = (id: string): BotRow => {
    const row = botRow(sqlite, id)
    if (row === undefined) throw new Error(`Bot not found: ${id}`)
    return row
  }

  const requireBot = (id: string): Bot => botFromRow(requireBotRow(id))

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
              record.mascot.color,
              record.mascot.hat,
              record.mascot.hatColor ?? autoColor,
              record.mascot.eyewear,
              record.mascot.eyewearColor ?? autoColor,
              record.slug,
              canonicalUuid(record.projectId),
              canonicalUuid(record.sessionId),
              canonicalUuid(record.workspaceId),
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
        const row = requireBotRow(id)
        const current = botFromRow(row)
        const mascot = nextMascot(mascotFromRow(row), record.mascot)
        sqlite
          .prepare(botSql.update)
          .run(
            record.name ?? current.name,
            record.symbolName ?? current.symbolName,
            mascot.color,
            mascot.hat,
            mascot.hatColor,
            mascot.eyewear,
            mascot.eyewearColor,
            nextArchivedAt(record.isArchived, row),
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
        if (row === undefined) return undefined
        return botFromRow(row)
      }),
    findBotLinkForSession: (sessionId) =>
      attempt("findBotLinkForSession", () => {
        const workspace = sessionWorkspace(sqlite, sessionId)
        if (workspace === undefined) return undefined
        const home = owningBotRow(sqlite, null, { workspaceId: workspace.id })
        if (home !== undefined) return { botId: home.id }
        return workspaceBotLink(workspaceFromRow(workspace))
      }),
    findFleetBotLink: (sessionId) =>
      attempt("findFleetBotLink", () => {
        const workspace = sessionWorkspace(sqlite, sessionId)
        if (workspace === undefined) return undefined
        return fleetBotLink(workspace)
      }),
    findWorkspaceFleetBotLink: (workspaceId) =>
      attempt("findWorkspaceFleetBotLink", () => {
        const workspace = workspaceById(sqlite, workspaceId)
        if (workspace === undefined) return undefined
        return fleetBotLink(workspace)
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

const sessionWorkspace = (sqlite: ServiceContext["sqlite"], sessionId: string) =>
  workspaceRows.maybe(sqlite.prepare(botSql.sessionWorkspace).get(canonicalUuid(sessionId)))

const workspaceBotLink = (workspace: Workspace): BotLink | undefined => {
  if (workspace.botId === undefined) return undefined
  if (workspace.botMachineId === undefined) return { botId: workspace.botId }
  return { botId: workspace.botId, botMachineId: workspace.botMachineId }
}

const workspaceById = (sqlite: ServiceContext["sqlite"], workspaceId: string) =>
  workspaceRows.maybe(sqlite.prepare(botSql.workspaceById).get(canonicalUuid(workspaceId)))

const fleetBotLink = (workspace: WorkspaceRow): RemoteBotLink | undefined => {
  const { remote_bot_id: botId, remote_bot_machine_id: botMachineId } = workspace
  const parentSessionId = workspace.remote_bot_parent_session_id
  if (botId == null || botMachineId == null || parentSessionId == null) return undefined
  return { parentSessionId, bot: { botId, botMachineId } }
}

interface StoredMascot extends BotMascot {
  readonly hatColor: string
  readonly eyewearColor: string
}

const autoColor = "auto"

const mascotFromRow = (row: BotRow): StoredMascot => ({
  color: row.mascot_color,
  hat: row.mascot_hat,
  hatColor: row.mascot_hat_color,
  eyewear: row.mascot_eyewear,
  eyewearColor: row.mascot_eyewear_color
})

const nextMascot = (current: StoredMascot, requested: BotMascot | undefined): StoredMascot => {
  if (requested === undefined) return current

  return {
    color: requested.color,
    hat: requested.hat,
    hatColor: requested.hatColor ?? keptColor(current.hat, requested.hat, current.hatColor),
    eyewear: requested.eyewear,
    eyewearColor:
      requested.eyewearColor ?? keptColor(current.eyewear, requested.eyewear, current.eyewearColor)
  }
}

const keptColor = (wornItem: string, nextItem: string, color: string): string =>
  wornItem === nextItem ? color : autoColor

const nextArchivedAt = (requested: boolean | undefined, row: BotRow): string | null => {
  if (requested === undefined || requested === (row.archived_at !== null)) return row.archived_at
  return requested ? isoTimestamp() : null
}

const touchBot = (sqlite: ServiceContext["sqlite"], id: string): void => {
  sqlite.prepare(botSql.touch).run(isoTimestamp(), id)
}

const botSql = {
  byId: `${botSelect} where bots.id = ?`,
  list: `${botSelect} order by bots.created_at asc, bots.id asc`,
  insert: `insert into bots (
                id, server_id, name, symbol_name, mascot_color, mascot_hat, mascot_hat_color,
                mascot_eyewear, mascot_eyewear_color, slug, project_id, session_id, workspace_id,
                created_at
              ) values (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)`,
  update: `update bots set name = ?, symbol_name = ?, mascot_color = ?, mascot_hat = ?,
       mascot_hat_color = ?, mascot_eyewear = ?, mascot_eyewear_color = ?,
       archived_at = ?, updated_at = ? where id = ?`,
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
  workspaceById: "select * from workspaces where id = ?",
  sessionWorkspace: `select workspaces.* from workspaces
                       join sessions on sessions.workspace_id = workspaces.id
                       where sessions.id = ?`,
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
