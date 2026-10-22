import type { FirstRunHarness, Harness } from "@codevisor/api"
import { FIRST_RUN_PROJECTS_PENDING, FIRST_RUN_PROJECTS_SETTING } from "@codevisor/db"

import { selectFirstRunProjects, type FirstRunProjectSelection } from "./first-run-projects.js"
import { failedFirstRunStatus, publishFirstRunStatus } from "./first-run-status.js"
import { discoverHarnesses } from "./routes/harnesses.js"
import { addProject } from "./routes/project-create.js"
import { recommendFromHarnesses } from "./routes/project-recommendations.js"
import {
  failureMessage,
  run,
  type CodevisorServerConfig,
  type CodevisorServerServices,
  type EventFanout,
  type FirstRunProjectsConfig
} from "./server-context.js"

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

  await publishFirstRunStatus(services, fanout, { state: "running" })
  const started = performance.now()
  await refreshHarnessEnvironment(services)
  const environmentMs = performance.now() - started
  const harnesses = (await discoverHarnesses(services)).filter(isInstalledHarness)
  const found = harnesses.map(foundHarness)
  await publishFirstRunStatus(services, fanout, { state: "running", harnesses: found })
  const recommendations = await recommendFromHarnesses(services, harnesses)
  const scanMs = performance.now() - started - environmentMs

  const selection = selectFirstRunProjects(recommendations, {
    now: Date.now(),
    homeDirectory: config.homeDirectory,
    excludedRoots: [config.dataDirectory],
    projectFolders: await localProjectFolders(services, serverId)
  })
  for (const [index, project] of selection.added.toReversed().entries()) {
    await addProject(services, fanout, { folderPath: project.path })
    await publishFirstRunStatus(services, fanout, {
      state: "running",
      harnesses: found,
      addedProjects: index + 1
    })
  }
  await run(services.db.setMachineSetting(FIRST_RUN_PROJECTS_SETTING, firstRunProjectsDone))
  await publishFirstRunStatus(services, fanout, {
    state: "done",
    harnesses: found,
    addedProjects: selection.added.length
  })

  debugLog(
    `scanned harness chats in ${Math.round(scanMs)}ms after ${Math.round(environmentMs)}ms resolving the shell environment; ${recommendations.length} candidate folders`
  )
  logSelection(selection)
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
