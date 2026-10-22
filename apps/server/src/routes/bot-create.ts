import { randomUUID } from "node:crypto"
import { mkdirSync, readdirSync } from "node:fs"
import type { IncomingMessage, ServerResponse } from "node:http"
import { basename, join } from "node:path"

import type { Bot, Project, SessionSummary } from "@codevisor/api"
import { CreateBotRequest as CreateBotRequestSchema } from "@codevisor/api"
import { botPath, botsRoot, legacyBotsRoot } from "@codevisor/db"
import {
  addWorktree,
  isGitWorkTree,
  listCodevisorWorktreeBranchNames,
  rollbackFailedWorktree,
  trashDirectory,
  worktreeStartPoint
} from "@codevisor/worktrees"

import {
  appendAndPublish,
  archiveJobs,
  assertLocationFolderExists,
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  readSchema,
  retireSessionRuntime,
  run,
  swallowError,
  worktreeTrashRoot,
  writeJson,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type RouteState
} from "../server-context.js"
import { writeInstructions, type BotRepository } from "./bot-instructions.js"
import { isBotProject, isScratchProject } from "./project-probe.js"
import { availableWorktreeName, slugifyWorktreeName } from "./project-worktree-create.js"
import { applySessionUpdate, createSessionIfMissing } from "./session-workspace.js"

interface BotSource {
  readonly project: Project
  readonly repoDir: string
}

export interface BotCheckout {
  readonly source: BotSource
  readonly folderName: string
  readonly path: string
  readonly branch: string
  readonly env: NodeJS.ProcessEnv
}

export const resolveSources = async (
  services: CodevisorServerServices,
  serverId: string,
  projectIds: ReadonlyArray<string>
): Promise<ReadonlyArray<BotSource>> => {
  const unique = [...new Map(projectIds.map((id) => [id.toLowerCase(), id])).values()]
  if (unique.length === 0) throw new HttpFailure(422, "A bot needs at least one project")
  const sources: Array<BotSource> = []
  for (const projectId of unique) {
    const project = await getProjectOrFail(services.db, projectId)
    const location = localLocationOrFail(serverId, project)
    assertLocationFolderExists(location)
    if (isScratchProject(project) || isBotProject(project)) {
      throw new HttpFailure(422, `${project.name} cannot be added to a bot`)
    }
    if (!(await isGitWorkTree(location.folderPath))) {
      throw new HttpFailure(422, `Project folder is not a git repository: ${location.folderPath}`)
    }
    sources.push({ project, repoDir: location.folderPath })
  }
  return sources
}

const allocateBotFolder = async (
  services: CodevisorServerServices,
  name: string
): Promise<string> => {
  mkdirSync(botsRoot(), { recursive: true })
  let legacyFolders: ReadonlyArray<string> = []
  try {
    legacyFolders = readdirSync(legacyBotsRoot())
  } catch {}
  const taken = new Set([
    ...readdirSync(botsRoot()),
    ...legacyFolders,
    ...(await run(services.db.listBots)).map((bot) => basename(bot.rootPath))
  ])
  const base = slugifyWorktreeName(name) ?? "bot"
  for (;;) {
    const candidate = availableWorktreeName(base, taken)
    try {
      mkdirSync(join(botsRoot(), candidate))
      return candidate
    } catch (cause) {
      /* v8 ignore start */
      if (!(cause instanceof Error && "code" in cause && cause.code === "EEXIST")) throw cause
      taken.add(candidate)
      /* v8 ignore stop */
    }
  }
}

export const checkOut = async (
  services: CodevisorServerServices,
  slug: string,
  source: BotSource,
  folders: Set<string>
): Promise<BotCheckout> => {
  const folderName = availableWorktreeName(
    slugifyWorktreeName(source.project.name) ?? "repo",
    folders
  )
  folders.add(folderName)
  const env = await (services.resolveGitEnvironment?.(source.repoDir) ??
    Promise.resolve(process.env))
  const branchName = availableWorktreeName(
    `bot-${slug}`,
    new Set(await listCodevisorWorktreeBranchNames(source.repoDir, env))
  )
  const checkout: BotCheckout = {
    source,
    folderName,
    path: join(botPath(slug), folderName),
    branch: `codevisor/${branchName}`,
    env
  }
  const startPoint = await worktreeStartPoint(source.repoDir, source.project.worktreeBase, env)
  try {
    await addWorktree(source.repoDir, checkout.path, checkout.branch, undefined, startPoint, env)
  } catch (cause) {
    await rollbackFailedWorktree(source.repoDir, checkout.path, checkout.branch, env).catch(
      swallowError
    )
    throw cause
  }
  return checkout
}

export const checkoutRepository = (checkout: BotCheckout): BotRepository => ({
  folderName: checkout.folderName,
  name: checkout.source.project.name,
  repoDir: checkout.source.repoDir,
  projectId: checkout.source.project.id
})

interface CreatedBotResources {
  readonly slug: string
  readonly checkouts: Array<BotCheckout>
  homeProjectId?: string
  session?: SessionSummary
}

const rollBack = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  created: CreatedBotResources
): Promise<void> => {
  if (created.session !== undefined) {
    await retireSessionRuntime(services, created.session).catch(swallowError)
  }
  if (created.homeProjectId !== undefined) {
    const projectId = created.homeProjectId
    await run(services.db.deleteProject(projectId)).catch(swallowError)
    const deletions: ReadonlyArray<
      readonly ["project.deleted" | "session.deleted" | "workspace.deleted", string | undefined]
    > = [
      ["session.deleted", created.session?.id],
      ["workspace.deleted", created.session?.workspaceId],
      ["project.deleted", projectId]
    ]
    for (const [kind, id] of deletions) {
      if (id === undefined) continue
      await appendAndPublish(services.db, fanout, kind, id, { id }).catch(swallowError)
    }
  }
  for (const checkout of created.checkouts.toReversed()) {
    await rollbackFailedWorktree(
      checkout.source.repoDir,
      checkout.path,
      checkout.branch,
      checkout.env
    ).catch(swallowError)
  }
  await trashDirectory(botPath(created.slug), {
    trashRoot: worktreeTrashRoot(),
    id: `bot-${created.slug}`
  })
    .then((trashed) => archiveJobs(services).track(trashed.purged))
    .catch(swallowError)
}

export const createBot = async (
  services: CodevisorServerServices,
  config: CodevisorServerConfig,
  fanout: EventFanout,
  routeState: RouteState,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const payload = await readSchema(request, CreateBotRequestSchema)
  let existing: Bot | undefined
  if (payload.id !== undefined) existing = await run(services.db.getBot(payload.id))
  if (existing !== undefined) {
    writeJson(response, 200, existing)
    return true
  }
  const name = payload.name.trim()
  if (name.length === 0) throw new HttpFailure(422, "A bot needs a name")
  const sources = await resolveSources(services, config.id, payload.projectIds)
  const slug = await allocateBotFolder(services, name)
  const created: CreatedBotResources = { slug, checkouts: [] }
  try {
    const folders = new Set<string>()
    for (const source of sources) {
      created.checkouts.push(await checkOut(services, slug, source, folders))
    }
    const conversational = payload.conversational === true
    writeInstructions(
      slug,
      name,
      payload.harnessId,
      conversational,
      created.checkouts.map(checkoutRepository)
    )
    const home = await run(services.db.createProject({ folderPath: botPath(slug), name }))
    created.homeProjectId = home.id
    await appendAndPublish(
      services.db,
      fanout,
      "project.created",
      home.id,
      await getProjectOrFail(services.db, home.id)
    )
    const workspaceId = randomUUID()
    const { session } = await createSessionIfMissing(services, fanout, routeState, config, {
      projectId: home.id,
      harnessId: payload.harnessId,
      ...(payload.configSelections === undefined
        ? {}
        : { configSelections: payload.configSelections }),
      workspaceId,
      title: name
    })
    await applySessionUpdate(services, fanout, session.id, { title: name, titleIntent: "rename" })
    created.session = session
    const bot = await run(
      services.db.createBot({
        id: (payload.id ?? randomUUID()).toLowerCase(),
        name,
        symbolName: payload.symbolName,
        slug,
        projectId: home.id,
        sessionId: session.id,
        workspaceId,
        conversational,
        projects: created.checkouts.map((checkout) => ({
          projectId: checkout.source.project.id,
          folderName: checkout.folderName,
          branch: checkout.branch
        }))
      })
    )
    await appendAndPublish(services.db, fanout, "bot.updated", bot.id, { id: bot.id })
    writeJson(response, 201, bot)
    return true
  } catch (cause) {
    await rollBack(services, fanout, created)
    throw cause
  }
}
