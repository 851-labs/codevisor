import { FirstRunFolderAnswer } from "@codevisor/api"
import { Schema } from "effect"

import { answerFirstRunFolder, isFolderAwaitingAnswer } from "../first-run-folder-answers.js"
import { readFirstRunStatus } from "../first-run-status.js"
import { HttpFailure, readJson, swallowError, writeJson } from "../server-context.js"
import type { RouteContext, RouteFamily } from "./route-context.js"

export const routeFirstRun: RouteFamily = async (route) => {
  const { services, request, response, url } = route
  if (url.pathname === "/v1/first-run" && request.method === "GET") {
    writeJson(response, 200, await readFirstRunStatus(services))
    return true
  }
  const folderId = answeredFolderId(url)
  if (folderId === undefined || request.method !== "POST") return false

  await answerFolder(route, folderId)
  return true
}

const folderAnswerPath = /^\/v1\/first-run\/folders\/([^/]+)$/u

const decodeAnswer = Schema.decodeUnknownOption(FirstRunFolderAnswer)

const answeredFolderId = (url: URL): string | undefined => {
  const encoded = folderAnswerPath.exec(url.pathname)?.[1]
  return encoded === undefined ? undefined : decodeURIComponent(encoded)
}

const answerFolder = async (
  { services, fanout, config, request, response }: RouteContext,
  folderId: string
): Promise<void> => {
  const answer = decodeAnswer(await readJson(request))
  if (answer._tag === "None") throw new HttpFailure(400, "Expected access: allow or decline")
  const firstRun = config.firstRunProjects
  if (firstRun === undefined || !(await isFolderAwaitingAnswer(services, folderId))) {
    throw new HttpFailure(404, "That folder isn't waiting for an answer")
  }

  void answerFirstRunFolder(
    { services, fanout, serverId: config.id, config: firstRun },
    folderId,
    answer.value.access
  ).catch(swallowError)
  writeJson(response, 200, await readFirstRunStatus(services))
}
