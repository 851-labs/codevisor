import { randomUUID } from "node:crypto"
import { existsSync, realpathSync } from "node:fs"
import { mkdir, rm, writeFile } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { homedir } from "node:os"
import { basename, dirname, join, sep } from "node:path"

import type {
  Project,
  ProjectCloneProgress,
  ProjectEnvFileContent,
  ProjectSetupUpdate
} from "@codevisor/api"
import {
  CreateProjectFromGitRequest as CreateProjectFromGitRequestSchema,
  ProjectSetupErrorCode,
  repoIdentityKey
} from "@codevisor/api"
import type { CodevisorDatabaseService } from "@codevisor/db"
import {
  alternateCloneUrl,
  CloneError,
  cloneRepository,
  cloneUrlHost,
  gitRemoteUrl,
  isGitWorkTree,
  parseCloneProgress,
  probeRemote
} from "@codevisor/worktrees"
import { Schema } from "effect"

import {
  appendAndPublish,
  existingDirectory,
  failureMessage,
  HttpFailure,
  readSchema,
  run,
  swallowError,
  writeJson,
  type CodevisorServerServices,
  type EventFanout
} from "../server-context.js"
import { cloneBaseFolder } from "./project-clone-settings.js"
import { cloneDirectoryName, looksLikeGitUrl } from "./project-git-url.js"
import { probeProject } from "./project-probe.js"
import {
  ENV_FILE_MAX_BYTES,
  gitEnvironment,
  isEnvFileName,
  isSafeRelativePath
} from "./project-setup-source.js"

interface ActiveSetup {
  readonly controller: AbortController
  readonly repository: string
}

const activeSetups = new Map<string, ActiveSetup>()
const PROGRESS_INTERVAL_MS = 250

export const cancelProjectSetup = (projectId: string): boolean => {
  const setup = activeSetups.get(projectId.toLowerCase())
  if (setup === undefined) return false
  setup.controller.abort()
  return true
}

export const routeProjectFromGit = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  const payload = await readSchema(request, CreateProjectFromGitRequestSchema)
  const repoUrl = payload.url.trim()
  if (!looksLikeGitUrl(repoUrl)) {
    throw new HttpFailure(400, `Not a git URL: ${payload.url}`, "invalid_url")
  }
  const name = payload.name?.trim() || cloneDirectoryName(repoUrl)
  if (name === undefined || name.length === 0) {
    throw new HttpFailure(
      400,
      "Could not derive a project name from the URL; pass one explicitly",
      "invalid_url"
    )
  }
  const envFiles = payload.envFiles ?? []
  assertWritableEnvFiles(envFiles)
  const repository = repoIdentityKey(repoUrl) ?? repoUrl
  const environment = await gitEnvironment(services)

  const existing = await existingProjectFor(services.db, serverId, repoUrl)
  if (existing !== undefined) {
    const { project: existingProject, folderPath } = existing
    await writeEnvFiles(folderPath, envFiles)
    const publishSetup = makeProjectSetupPublisher(
      services.db,
      fanout,
      payload.id ?? existingProject.id,
      repoUrl
    )
    await publishSetup({ state: "completed", folderPath, durationMs: 0 })
    writeJson(response, 200, await probeProject(serverId, existingProject))
    return
  }
  if ([...activeSetups.values()].some((setup) => setup.repository === repository)) {
    throw new HttpFailure(
      409,
      "This repository is already being set up on this machine",
      "in_progress"
    )
  }

  const newProjectId = payload.id ?? randomUUID()
  const controller = new AbortController()
  activeSetups.set(newProjectId.toLowerCase(), { controller, repository })
  const publishSetup = makeProjectSetupPublisher(services.db, fanout, newProjectId, repoUrl)
  const startedAt = Date.now()
  let createdFolder: string | undefined
  try {
    await publishSetup({ state: "started" })
    const destination = await chooseDestination({
      name,
      repoUrl,
      homeRelativePath: payload.homeRelativePath,
      baseFolder: await cloneBaseFolder(services.db),
      env: environment
    })
    let clonedUrl = repoUrl
    if (!destination.adopt) {
      await publishSetup({ state: "progress", progress: { stage: "connecting" } })
      clonedUrl = await reachableCloneUrl(repoUrl, environment, controller.signal)
      await mkdir(dirname(destination.path), { recursive: true })
      createdFolder = destination.path
      await cloneRepository(
        clonedUrl,
        destination.path,
        cloneOutputPublisher(publishSetup),
        environment,
        controller.signal
      )
    }
    if (envFiles.length > 0) {
      await publishSetup({ state: "progress", progress: { stage: "copying" } })
      await writeEnvFiles(destination.path, envFiles)
    }
    const created = await run(
      services.db.createProject({
        id: newProjectId,
        folderPath: destination.path,
        name,
        repoUrl: clonedUrl
      })
    )
    const project = await run(
      services.db.updateProject(created.id, {
        ...(payload.worktreeBase === undefined ? {} : { worktreeBase: payload.worktreeBase }),
        ...(payload.defaultRunLocation === undefined
          ? {}
          : { defaultRunLocation: payload.defaultRunLocation })
      })
    )
    createdFolder = undefined
    await publishSetup({
      state: "completed",
      folderPath: destination.path,
      durationMs: Date.now() - startedAt
    })
    await appendAndPublish(services.db, fanout, "project.created", project.id, project)
    writeJson(response, 201, await probeProject(serverId, project))
  } catch (cause) {
    const code =
      cause instanceof CloneError || cause instanceof HttpFailure
        ? setupErrorCode(cause.code)
        : /* v8 ignore next */ undefined
    const host = cloneUrlHost(repoUrl)
    await publishSetup({
      state: "failed",
      message: failureMessage(cause),
      ...(code === undefined ? {} : { code }),
      ...(host === undefined ? {} : { host }),
      durationMs: Date.now() - startedAt
    })
    if (createdFolder !== undefined) await rm(createdFolder, { force: true, recursive: true })
    throw cause
  } finally {
    activeSetups.delete(newProjectId.toLowerCase())
  }
}

const sameRepository = (left: string | undefined, right: string): boolean =>
  left !== undefined && (repoIdentityKey(left) ?? left) === (repoIdentityKey(right) ?? right)

const existingProjectFor = async (
  db: CodevisorDatabaseService,
  serverId: string,
  repoUrl: string
): Promise<{ readonly project: Project; readonly folderPath: string } | undefined> => {
  for (const project of await run(db.listProjects)) {
    const folderPath = project.locations
      .filter((location) => location.serverId === serverId)
      .map((location) => location.folderPath)
      .find((path) => existingDirectory(path) !== undefined)
    if (folderPath !== undefined && sameRepository(project.repoUrl, repoUrl)) {
      return { project, folderPath }
    }
  }
  return undefined
}

interface DestinationChoice {
  readonly path: string
  readonly adopt: boolean
}

export const MAX_CLONE_FOLDER_SUFFIX = 50

const chooseDestination = async (options: {
  readonly name: string
  readonly repoUrl: string
  readonly homeRelativePath: string | undefined
  readonly baseFolder: string
  readonly env: NodeJS.ProcessEnv
}): Promise<DestinationChoice> => {
  const mirrored =
    options.homeRelativePath !== undefined && isSafeRelativePath(options.homeRelativePath)
      ? [join(homedir(), options.homeRelativePath)]
      : []
  const candidates = [
    ...mirrored,
    join(options.baseFolder, options.name),
    ...Array.from({ length: MAX_CLONE_FOLDER_SUFFIX - 1 }, (_, index) =>
      join(options.baseFolder, `${options.name}-${String(index + 2)}`)
    )
  ]
  for (const path of candidates) {
    if (!existsSync(path)) return { path, adopt: false }
    if (await isCloneOf(path, options.repoUrl, options.env)) return { path, adopt: true }
  }
  throw new HttpFailure(
    409,
    `No free folder for ${options.name} in ${options.baseFolder}`,
    "already_exists"
  )
}

const isCloneOf = async (path: string, repoUrl: string, env: NodeJS.ProcessEnv): Promise<boolean> =>
  (await isGitWorkTree(path)) && sameRepository(await gitRemoteUrl(path, env), repoUrl)

const reachableCloneUrl = async (
  repoUrl: string,
  env: NodeJS.ProcessEnv,
  signal: AbortSignal
): Promise<string> => {
  const first = await probeRemote(repoUrl, env, signal)
  if (first.ok) return repoUrl
  const alternate = alternateCloneUrl(repoUrl)
  if (alternate !== undefined && (await probeRemote(alternate, env, signal)).ok) return alternate
  throw new CloneError(first.message, first.code)
}

const cloneOutputPublisher = (
  publishSetup: ProjectSetupPublisher
): ((stream: "stdout" | "stderr", line: string) => void) => {
  let lastAt = 0
  let lastStage: ProjectCloneProgress["stage"] | undefined
  return (stream, line) => {
    const progress = parseCloneProgress(line)
    if (progress === undefined) {
      if (line.startsWith("Cloning into")) return
      void publishSetup({ state: "log", stream, line }).catch(swallowError)
      return
    }
    const now = Date.now()
    const throttled = progress.stage === lastStage && progress.percent !== 100
    if (throttled && now - lastAt < PROGRESS_INTERVAL_MS) return
    lastAt = now
    lastStage = progress.stage
    void publishSetup({ state: "progress", progress }).catch(swallowError)
  }
}

const assertWritableEnvFiles = (files: ReadonlyArray<ProjectEnvFileContent>): void => {
  for (const file of files) {
    if (!isSafeRelativePath(file.path) || !isEnvFileName(basename(file.path))) {
      throw new HttpFailure(400, `Not an env file path: ${file.path}`)
    }
    if (Buffer.byteLength(file.contents, "utf8") > ENV_FILE_MAX_BYTES) {
      throw new HttpFailure(400, `Env file is too large: ${file.path}`)
    }
  }
}

const writeEnvFiles = async (
  root: string,
  files: ReadonlyArray<ProjectEnvFileContent>
): Promise<void> => {
  const realRoot = realpathSync(root)
  for (const file of files) {
    const target = join(realRoot, file.path)
    await mkdir(dirname(target), { recursive: true })
    if (!`${realpathSync(dirname(target))}${sep}`.startsWith(`${realRoot}${sep}`)) {
      throw new HttpFailure(400, `Env file escapes the project folder: ${file.path}`)
    }
    if (!existsSync(target)) await writeFile(target, file.contents, { mode: 0o600 })
  }
}

const isSetupErrorCode = Schema.is(ProjectSetupErrorCode)

const setupErrorCode = (code: string | undefined): ProjectSetupUpdate["code"] =>
  isSetupErrorCode(code) ? code : undefined

type ProjectSetupPublisher = (
  detail: Partial<ProjectSetupUpdate> & { state: ProjectSetupUpdate["state"] }
) => Promise<void>

const makeProjectSetupPublisher = (
  db: CodevisorDatabaseService,
  fanout: EventFanout,
  projectId: string,
  repoUrl: string
): ProjectSetupPublisher => {
  let chain: Promise<void> = Promise.resolve()
  return (detail) => {
    const update: ProjectSetupUpdate = {
      projectId,
      url: repoUrl,
      ...detail
    }
    const next = chain.then(async () => {
      await appendAndPublish(db, fanout, "project.setup", projectId, update)
    })
    /* v8 ignore next */
    chain = next.catch(() => undefined)
    return next
  }
}
