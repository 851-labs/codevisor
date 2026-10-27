import { CreatePluginEventSubscriptionRequest } from "@codevisor/api"
import { Schema } from "effect"

import type { PluginEvents } from "../plugins/events/plugin-events.js"
import { HttpFailure, matchRoute, readSchema, writeJson } from "../server-context.js"
import type { RouteContext } from "./route-context.js"

export const routePluginEvents = async (route: RouteContext): Promise<boolean> => {
  const { url, request } = route
  if (!url.pathname.startsWith("/v1/plugins/events")) return false
  const events = requireEvents(route)

  const handler = collectionHandlers[`${String(request.method)} ${url.pathname}`]
  if (handler !== undefined) return respond(route, await handler(events, route))

  const subscriptionId = matchRoute(url.pathname, "/v1/plugins/events/subscriptions/:id")
  if (subscriptionId !== undefined && request.method === "DELETE") {
    return respond(route, { removed: await events.unsubscribe(subscriptionId) })
  }

  const eventId = matchRoute(url.pathname, "/v1/plugins/events/:id")
  if (eventId !== undefined && request.method === "GET") {
    return respond(route, await requireEvent(events, eventId))
  }
  return false
}

const PreviewRequest = Schema.Struct({
  plugin: Schema.String,
  event: Schema.String,
  filter: Schema.optional(Schema.String),
  accountId: Schema.optional(Schema.String)
})

type CollectionHandler = (events: PluginEvents, route: RouteContext) => Promise<unknown>

const collectionHandlers: Readonly<Record<string, CollectionHandler>> = {
  "GET /v1/plugins/events/types": async (events, { url }) => ({
    types: await events.types(url.searchParams.get("query") ?? undefined)
  }),
  "GET /v1/plugins/events/subscriptions": async (events, { url }) => ({
    subscriptions: await events.subscriptions(url.searchParams.get("sessionId") ?? undefined)
  }),
  "POST /v1/plugins/events/subscriptions": async (events, { request }) =>
    events.subscribe(await readSchema(request, CreatePluginEventSubscriptionRequest)),
  "POST /v1/plugins/events/preview": async (events, { request }) =>
    events.preview(previewRequest(await readSchema(request, PreviewRequest)))
}

const respond = (route: RouteContext, body: unknown): boolean => {
  writeJson(route.response, 200, body)
  return true
}

const requireEvents = (route: RouteContext): PluginEvents => {
  const events = route.routeState.pluginEvents
  if (events === undefined) throw new HttpFailure(501, "Plugin events unavailable")
  return events
}

const requireEvent = async (events: PluginEvents, eventId: string) => {
  const event = await events.event(eventId)
  if (event === undefined) throw new HttpFailure(404, `Event not found: ${eventId}`)
  return event
}

const previewRequest = (decoded: typeof PreviewRequest.Type) => ({
  plugin: decoded.plugin,
  event: decoded.event,
  ...(decoded.filter === undefined ? {} : { filter: decoded.filter }),
  ...(decoded.accountId === undefined ? {} : { accountId: decoded.accountId })
})
