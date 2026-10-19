import type { IncomingMessage, ServerResponse } from "node:http"

import {
  CreateSessionSubscriptionRequest,
  DEFAULT_EXECUTION_JOB_WAIT_TIMEOUT_MS,
  DEFAULT_SUBSCRIPTION_EVENTS,
  MAX_EXECUTION_JOB_WAIT_TIMEOUT_MS,
  WaitForExecutionJobRequest,
  type ExecutionJob
} from "@codevisor/api"
import type { ExecutionJobs } from "@codevisor/mcp"

import {
  HttpFailure,
  matchRoute,
  matchRouteParams,
  readSchema,
  run,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"
import { routeParam } from "./route-params.js"

export const routeSessionEvents = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  if (await routeSubscriptions(services, request, response, url)) return true
  return routeJobs(services, request, response, url)
}

const routeSubscriptions = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const subscriberId = matchRoute(url.pathname, "/v1/sessions/:id/subscriptions")
  if (subscriberId !== undefined && request.method === "GET") {
    const subscriptions = await run(services.db.listSessionSubscriptions(subscriberId))
    writeJson(response, 200, { subscriptions })
    return true
  }

  if (subscriberId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, CreateSessionSubscriptionRequest)
    await assertSubscribable(services, subscriberId, payload.targetSessionId)
    const subscription = await run(
      services.db.createSessionSubscription({
        subscriberSessionId: subscriberId,
        targetSessionId: payload.targetSessionId,
        events: payload.events ?? DEFAULT_SUBSCRIPTION_EVENTS,
        once: payload.once === true
      })
    )
    writeJson(response, 201, subscription)
    return true
  }

  const subscriptionRoute = matchRouteParams(
    url.pathname,
    "/v1/sessions/:id/subscriptions/:subscriptionId"
  )
  if (subscriptionRoute === undefined || request.method !== "DELETE") return false

  const id = routeParam(subscriptionRoute, "id")
  const subscriptionId = routeParam(subscriptionRoute, "subscriptionId")
  const held = await run(services.db.listSessionSubscriptions(id))
  if (!held.some((subscription) => subscription.id === subscriptionId)) {
    throw new HttpFailure(404, `Subscription not found: ${subscriptionId}`)
  }
  await run(services.db.deleteSessionSubscription(subscriptionId))
  writeJson(response, 204, {})
  return true
}

const routeJobs = async (
  services: CodevisorServerServices,
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const sessionId = matchRoute(url.pathname, "/v1/sessions/:id/jobs")
  if (sessionId !== undefined && request.method === "GET") {
    writeJson(response, 200, { jobs: jobsOf(services).list(sessionId) })
    return true
  }

  const jobId = matchRoute(url.pathname, "/v1/jobs/:jobId")
  if (jobId !== undefined && request.method === "GET") {
    writeJson(response, 200, knownJob(jobsOf(services).get(jobId), jobId))
    return true
  }

  const waitId = matchRoute(url.pathname, "/v1/jobs/:jobId/wait")
  if (waitId !== undefined && request.method === "POST") {
    const payload = await readSchema(request, WaitForExecutionJobRequest)
    const abort = new AbortController()
    response.once("close", () => abort.abort())
    const waited = await jobsOf(services).wait(waitId, jobWaitMs(payload.timeoutMs), abort.signal)
    if (waited === undefined) throw unknownJob(waitId)
    writeJson(response, 200, waited)
    return true
  }

  const cancelId = matchRoute(url.pathname, "/v1/jobs/:jobId/cancel")
  if (cancelId !== undefined && request.method === "POST") {
    writeJson(response, 200, knownJob(await jobsOf(services).cancel(cancelId), cancelId))
    return true
  }

  return false
}

const assertSubscribable = async (
  services: CodevisorServerServices,
  subscriberId: string,
  targetId: string
): Promise<void> => {
  if (subscriberId.toLowerCase() === targetId.toLowerCase()) {
    throw new HttpFailure(422, "A session can't subscribe to its own events")
  }
  await run(services.db.getSessionSummary(subscriberId))
  const target = await run(services.db.getSessionSummary(targetId)).catch(() => undefined)
  if (target === undefined) throw new HttpFailure(404, `Session not found: ${targetId}`)
}

const jobsOf = (services: CodevisorServerServices): ExecutionJobs => {
  /* v8 ignore next */
  if (services.mcp === undefined) {
    throw new HttpFailure(503, "Background jobs need the Codevisor tool gateway")
  }
  return services.mcp.jobs
}

const knownJob = (job: ExecutionJob | undefined, jobId: string): ExecutionJob => {
  if (job === undefined) throw unknownJob(jobId)
  return job
}

const unknownJob = (jobId: string): HttpFailure =>
  new HttpFailure(
    404,
    `Job not found: ${jobId}. Jobs last until an hour after they finish and don't survive a server restart.`
  )

const jobWaitMs = (requested: number | undefined): number =>
  Math.min(
    Math.max(0, requested ?? DEFAULT_EXECUTION_JOB_WAIT_TIMEOUT_MS),
    MAX_EXECUTION_JOB_WAIT_TIMEOUT_MS
  )
