import { randomUUID } from "node:crypto"

import { FORK_COMMAND } from "@codevisor/agent-runtime"
import { isoTimestamp, type SessionSummary } from "@codevisor/api"

import { appendAndPublish, HttpFailure, run, writeJson } from "../server-context.js"
import { hasLiveTurn } from "./prompt-queue.js"
import type { RouteContext } from "./route-context.js"
import { createSessionIfMissing, ensureAgentSessionFor } from "./session-workspace.js"
import { deleteServerSession } from "./sessions.js"

export const forkSession = async (route: RouteContext, sessionId: string): Promise<boolean> => {
  const source = await forkableSource(route, sessionId)
  const sourceAgentSessionId = await forkableAgentSession(route, source)

  const fork = await createForkSession(route, source)
  try {
    await copyTranscript(route, source, fork)
    await ensureAgentSessionFor(route.services, route.fanout, route.config.id, fork.id, {
      forkFrom: sourceAgentSessionId
    })
    writeJson(route.response, 201, await announceFork(route, fork.id))
    return true
  } catch (cause) {
    await deleteServerSession(route.services, route.fanout, fork.id)
    throw cause
  }
}

const forkableSource = async (route: RouteContext, sessionId: string): Promise<SessionSummary> => {
  const { services, routeState } = route
  const source = await run(services.db.getSessionSummary(sessionId))
  if (hasLiveTurn(routeState, sessionId)) {
    throw new HttpFailure(409, "Wait for the agent to finish before forking this chat")
  }
  return source
}

const forkableAgentSession = async (
  route: RouteContext,
  source: SessionSummary
): Promise<string> => {
  if (source.agentSessionId === undefined || source.agentSessionId === "") {
    throw new HttpFailure(409, "Send a message before forking this chat")
  }
  if (!(await canFork(route, source))) {
    throw new HttpFailure(409, "This agent can't fork chats")
  }
  return source.agentSessionId
}

const canFork = async (route: RouteContext, source: SessionSummary): Promise<boolean> => {
  const saved = await run(route.services.db.getSessionSkills(source.id))
  if (saved?.commands?.includes(FORK_COMMAND) === true) return true
  const loaded = await ensureAgentSessionFor(
    route.services,
    route.fanout,
    route.config.id,
    source.id
  )
  return loaded.skills?.commands?.includes(FORK_COMMAND) === true
}

const createForkSession = async (
  { services, fanout, routeState, config }: RouteContext,
  source: SessionSummary
): Promise<SessionSummary> => {
  const created = await createSessionIfMissing(
    services,
    fanout,
    routeState,
    config,
    {
      projectId: source.projectId,
      harnessId: source.harnessId,
      title: forkTitle(source),
      workspaceId: randomUUID(),
      parentSessionId: source.id,
      deferAgentSession: true,
      ...(source.harnessAccountId === undefined
        ? {}
        : { harnessAccountId: source.harnessAccountId }),
      ...(source.worktreeName === undefined ? {} : { worktreeName: source.worktreeName })
    },
    false
  )
  return run(
    services.db.updateSession(created.session.id, {
      title: created.session.title,
      titleIntent: "rename"
    })
  )
}

const announceFork = async (
  { services, fanout }: RouteContext,
  forkId: string
): Promise<SessionSummary> => {
  const fork = await run(services.db.getSessionSummary(forkId))
  await appendAndPublish(services.db, fanout, "session.created", fork.id, fork)
  return fork
}

const copyTranscript = (
  { services }: RouteContext,
  source: SessionSummary,
  fork: SessionSummary
): Promise<void> =>
  run(
    services.db.copySessionTranscript(source.id, fork.id, {
      text: `Forked from ${source.title}`,
      createdAt: isoTimestamp()
    })
  )

const forkSuffix = " (fork)"

const forkTitle = (source: SessionSummary): string =>
  source.title.endsWith(forkSuffix) ? source.title : `${source.title}${forkSuffix}`
