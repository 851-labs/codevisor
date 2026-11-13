import type {
  FirstRunHarness,
  FirstRunProject,
  FirstRunStatus,
  Harness,
  ProjectRecommendation
} from "@codevisor/api"
import { FIRST_RUN_PROJECTS_PENDING, FIRST_RUN_PROJECTS_SETTING } from "@codevisor/db"

import { groupByFolder, savePendingFolders } from "./first-run-folders.js"
import {
  firstRunProjectLimit,
  selectFirstRunProjects,
  type FirstRunProjectContext,
  type FirstRunProjectSelection
} from "./first-run-projects.js"
import { failedFirstRunStatus, publishFirstRunStatus } from "./first-run-status.js"
import { scanSessionFolders, type HeldProject } from "./project-recommendations.js"
import { beginFolderDecisions, folderAccess } from "./protected-folders.js"
import { discoverHarnesses } from "./routes/harnesses.js"
import { addProject } from "./routes/project-create.js"
import { listHarnessSessions, sessionScanLimit } from "./routes/project-recommendations.js"
import {
  failureMessage,
  run,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type FirstRunProjectsConfig
} from "./server-context.js"

export interface FirstRun {
  readonly services: CodevisorServerServices
  readonly fanout: EventFanout
  readonly serverId: string
  readonly config: FirstRunProjectsConfig
}

export const startFirstRunProjectImport = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  config: CodevisorServerConfig
): Promise<void> => {
  const firstRun = config.firstRunProjects
  if (firstRun === undefined) return

  try {
    await importFirstRunProjects(services, fanout, config.id, firstRun)
  } catch (cause) {
    debugLog(`failed: ${failureMessage(cause)}`)
    await publishFirstRunStatus(services, fanout, failedFirstRunStatus(services)).catch(
      () => undefined
    )
  }
}

export const importFirstRunProjects = async (
  services: CodevisorServerServices,
  fanout: EventFanout,
  serverId: string,
  config: FirstRunProjectsConfig
): Promise<void> => {
  if (!(await isFirstRunPending(services))) return

  const firstRun: FirstRun = { services, fanout, serverId, config }
  await publishFirstRunStatus(services, fanout, { state: "running" })
  const started = performance.now()
  await refreshHarnessEnvironment(services)
  const environmentMs = performance.now() - started
  const harnesses = (await discoverHarnesses(services)).filter(isInstalledHarness)
  const found = harnesses.map(foundHarness)
  await publishFirstRunStatus(services, fanout, { state: "running", harnesses: found })
  const scan = await scanHarnessSessions(firstRun, harnesses)
  const scanMs = performance.now() - started - environmentMs

  const selection = selectFirstRunProjects(scan.recommendations, await selectionContext(firstRun))
  const added = await addFirstRunProjects(firstRun, selection.added.toReversed(), {
    state: "running",
    harnesses: found
  })
  await holdFolders(firstRun, scan.held, firstRunProjectLimit - added.length)
  await run(services.db.setMachineSetting(FIRST_RUN_PROJECTS_SETTING, firstRunProjectsDone))
  await publishFirstRunStatus(services, fanout, {
    state: "done",
    harnesses: found,
    projects: added
  })

  debugLog(
    `scanned harness chats in ${Math.round(scanMs)}ms after ${Math.round(environmentMs)}ms resolving the shell environment; ${scan.recommendations.length} candidate folders`
  )
  logSelection(selection)
}

export const selectionContext = async (
  firstRun: FirstRun,
  limit: number = firstRunProjectLimit
): Promise<FirstRunProjectContext> => ({
  now: Date.now(),
  homeDirectory: firstRun.config.homeDirectory,
  excludedRoots: [firstRun.config.dataDirectory],
  projectFolders: await localProjectFolders(firstRun.services, firstRun.serverId),
  limit
})

export const addFirstRunProjects = async (
  { services, fanout }: FirstRun,
  candidates: ReadonlyArray<ProjectRecommendation>,
  progress: FirstRunStatus
): Promise<ReadonlyArray<FirstRunProject>> => {
  const before = progress.projects ?? []
  const added: Array<FirstRunProject> = []
  for (const candidate of candidates) {
    const project = await addProject(services, fanout, { folderPath: candidate.path })
    added.push({ id: project.id, name: project.name })
    await publishFirstRunStatus(services, fanout, { ...progress, projects: [...before, ...added] })
  }
  return added
}

const firstRunProjectsDone = "done"

const isFirstRunPending = async (services: CodevisorServerServices): Promise<boolean> =>
  (await run(services.db.getMachineSetting(FIRST_RUN_PROJECTS_SETTING))) ===
  FIRST_RUN_PROJECTS_PENDING

const refreshHarnessEnvironment = async (services: CodevisorServerServices): Promise<void> => {
  try {
    await run(services.agents.refreshEnvironment)
  } catch {}
}

const scanHarnessSessions = async (firstRun: FirstRun, harnesses: ReadonlyArray<Harness>) => {
  const sessions = await listHarnessSessions(firstRun.services, harnesses)
  const decisions = await beginFolderDecisions(firstRun.services)
  return scanSessionFolders(sessions, {
    limit: sessionScanLimit,
    access: folderAccess(decisions, firstRun.config)
  })
}

const holdFolders = async (
  firstRun: FirstRun,
  held: ReadonlyArray<HeldProject>,
  remaining: number
): Promise<void> => {
  const context = await selectionContext(firstRun, remaining)
  const worthAsking = new Set(
    selectFirstRunProjects(
      held.map((entry) => entry.project),
      context
    ).added
  )
  const folders = groupByFolder(held.filter((entry) => worthAsking.has(entry.project)))
  await savePendingFolders(firstRun.services, { remaining, folders })
}

const isInstalledHarness = (harness: Harness): boolean =>
  harness.readiness.state === "ready" && harness.desiredEnabled !== false

const foundHarness = (harness: Harness): FirstRunHarness => ({ id: harness.id, name: harness.name })

const localProjectFolders = async (
  services: CodevisorServerServices,
  serverId: string
): Promise<ReadonlyArray<string>> =>
  (await run(services.db.listProjects))
    .flatMap((project) => project.locations)
    .filter((location) => location.serverId === serverId)
    .map((location) => location.folderPath)

const logSelection = (selection: FirstRunProjectSelection): void => {
  for (const project of selection.added) {
    debugLog(`added ${project.path} (${project.sessionCount} chats, last ${project.lastActivity})`)
  }
  for (const skipped of selection.skipped) debugLog(`skipped ${skipped.path}: ${skipped.reason}`)
}

const debugLog = (message: string): void => {
  if (process.env.CODEVISOR_DEBUG === undefined) return
  console.debug(`[first-run-projects] ${message}`)
}
