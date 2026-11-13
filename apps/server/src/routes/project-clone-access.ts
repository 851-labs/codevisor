import type { IncomingMessage, ServerResponse } from "node:http"

import { CheckProjectCloneAccessRequest as CheckProjectCloneAccessRequestSchema } from "@codevisor/api"
import type { ProjectCloneAccess } from "@codevisor/api"
import {
  alternateCloneUrl,
  CloneError,
  moreTellingFailure,
  probeRemote,
  type RemoteProbeResult
} from "@codevisor/worktrees"

import { readSchema, writeJson, type CodevisorServerServices } from "../server-context.js"
import { logCloneFailure } from "./project-clone-log.js"
import { looksLikeGitUrl } from "./project-git-url.js"
import { gitEnvironment } from "./project-setup-source.js"

export const routeProjectCloneAccess = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  const payload = await readSchema(request, CheckProjectCloneAccessRequestSchema)
  const repoUrl = payload.url.trim()
  if (!looksLikeGitUrl(repoUrl)) return writeJson(response, 200, invalidUrl)

  const probe = await probeCloneUrls(repoUrl, await gitEnvironment(services))
  writeJson(response, 200, cloneAccess(probe))
}

export const reachableCloneUrl = async (
  repoUrl: string,
  env: NodeJS.ProcessEnv,
  signal: AbortSignal
): Promise<string> => {
  const probe = await probeCloneUrls(repoUrl, env, signal)
  if (!probe.ok) throw new CloneError(probe.message, probe.code)
  return probe.url
}

interface CloneUrlProbe extends RemoteProbeResult {
  readonly url: string
}

const invalidUrl: ProjectCloneAccess = { ok: false, code: "invalid_url" }

const probeCloneUrls = async (
  repoUrl: string,
  env: NodeJS.ProcessEnv,
  signal?: AbortSignal
): Promise<CloneUrlProbe> => {
  const first = await probeAndLog(repoUrl, env, signal)
  if (first.ok) return { ...first, url: repoUrl }

  const alternate = alternateCloneUrl(repoUrl)
  if (alternate === undefined) return { ...first, url: repoUrl }

  const second = await probeAndLog(alternate, env, signal)
  if (second.ok) return { ...second, url: alternate }
  return { ...moreTellingFailure(first, second), url: repoUrl }
}

const probeAndLog = async (
  url: string,
  env: NodeJS.ProcessEnv,
  signal: AbortSignal | undefined
): Promise<RemoteProbeResult> => {
  const result = await probeRemote(url, env, signal)
  if (!result.ok) logCloneFailure(url, result)
  return result
}

const cloneAccess = (probe: CloneUrlProbe): ProjectCloneAccess => {
  if (probe.ok || probe.code === undefined) return { ok: probe.ok }
  return { ok: false, code: probe.code }
}
