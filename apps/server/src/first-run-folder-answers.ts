import type { AgentSessionSummary, FirstRunFolderAnswer, FirstRunProject } from "@codevisor/api"

import {
  readPendingFolders,
  savePendingFolders,
  withoutFolder,
  type PendingFolder
} from "./first-run-folders.js"
import { addFirstRunProjects, selectionContext, type FirstRun } from "./first-run-project-import.js"
import { selectFirstRunProjects } from "./first-run-projects.js"
import { publishFirstRunStatus, readFirstRunStatus } from "./first-run-status.js"
import { recommendProjectsFromSessions } from "./project-recommendations.js"
import { recordFolderDecision } from "./protected-folders.js"
import { sessionScanLimit } from "./routes/project-recommendations.js"
import type { CodevisorServerServices } from "./server-context.js"

export type FolderAccessAnswer = FirstRunFolderAnswer["access"]

export const isFolderAwaitingAnswer = async (
  services: CodevisorServerServices,
  folderId: string
): Promise<boolean> =>
  (await readPendingFolders(services)).folders.some((folder) => folder.id === folderId)

export const answerFirstRunFolder = (
  firstRun: FirstRun,
  folderId: string,
  answer: FolderAccessAnswer
): Promise<void> => {
  const earlier = answering.get(firstRun.services) ?? Promise.resolve()
  const settled = earlier.then(() => settleFolder(firstRun, folderId, answer))
  answering.set(
    firstRun.services,
    settled.catch(() => undefined)
  )
  return settled
}

const answering = new WeakMap<CodevisorServerServices, Promise<void>>()

const settleFolder = async (
  firstRun: FirstRun,
  folderId: string,
  answer: FolderAccessAnswer
): Promise<void> => {
  const { services, fanout } = firstRun
  const pending = await readPendingFolders(services)
  const folder = pending.folders.find((candidate) => candidate.id === folderId)
  if (folder === undefined) return

  const isReadable = answer === "allow" && (await firstRun.config.canReadFolder(folder.path))
  await recordFolderDecision(services, folder.id, isReadable ? "allowed" : "declined")
  let added: ReadonlyArray<FirstRunProject> = []
  if (isReadable) added = await addFolderProjects(firstRun, folder, pending.remaining)

  await savePendingFolders(services, {
    remaining: pending.remaining - added.length,
    folders: withoutFolder(pending, folder.id).folders
  })
  await publishFirstRunStatus(services, fanout, await readFirstRunStatus(services))
}

const addFolderProjects = async (
  firstRun: FirstRun,
  folder: PendingFolder,
  remaining: number
): Promise<ReadonlyArray<FirstRunProject>> => {
  const found = recommendProjectsFromSessions(folder.projects.map(asSession), {
    limit: sessionScanLimit
  })
  const selection = selectFirstRunProjects(found, await selectionContext(firstRun, remaining))
  const progress = await readFirstRunStatus(firstRun.services)
  return addFirstRunProjects(firstRun, selection.added.toReversed(), progress)
}

const asSession = (project: PendingFolder["projects"][number]): AgentSessionSummary => ({
  sessionId: project.path,
  cwd: project.path,
  ...(project.lastActivity === undefined ? {} : { updatedAt: project.lastActivity })
})
