import type { IncomingMessage, ServerResponse } from "node:http"

import { SavedProjectWork } from "@codevisor/api"
import { restoreSavedWork, saveWork, type SavedWork } from "@codevisor/worktrees"

import {
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  readSchema,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const SAVED_WORK_MAX_BYTES = 32 * 1024 * 1024

export const saveProjectWork = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string,
  response: ServerResponse
): Promise<boolean> => {
  const checkout = await projectCheckout(services, serverId, projectId)
  const work = await saveWork(checkout.folderPath, checkout.environment)
  if (work.bundle.byteLength > SAVED_WORK_MAX_BYTES) {
    throw new HttpFailure(413, tooLargeMessage(work.bundle.byteLength))
  }
  writeJson(response, 200, savedProjectWork(work))
  return true
}

export const restoreProjectWork = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<boolean> => {
  const work = await readSchema(request, SavedProjectWork)
  const checkout = await projectCheckout(services, serverId, projectId)
  await restoreSavedWork(checkout.folderPath, savedWorkOf(work), checkout.environment)
  writeJson(response, 204, undefined)
  return true
}

const projectCheckout = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string
) => {
  const project = await getProjectOrFail(services.db, projectId)
  const { folderPath } = localLocationOrFail(serverId, project)
  return { folderPath, environment: await services.resolveGitEnvironment?.(folderPath) }
}

const savedWorkOf = (work: SavedProjectWork): SavedWork => ({
  ...(work.branch === undefined ? {} : { branch: work.branch }),
  head: work.head,
  snapshot: work.snapshot,
  bundle: Buffer.from(work.bundle, "base64")
})

const savedProjectWork = (work: SavedWork): SavedProjectWork => ({
  ...(work.branch === undefined ? {} : { branch: work.branch }),
  head: work.head,
  snapshot: work.snapshot,
  bundle: work.bundle.toString("base64")
})

const megabytes = (bytes: number): string => `${String(Math.ceil(bytes / (1024 * 1024)))} MB`

const tooLargeMessage = (bytes: number): string =>
  `Its unpushed work is ${megabytes(bytes)}, more than the ${megabytes(SAVED_WORK_MAX_BYTES)} Codevisor keeps`
