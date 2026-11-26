import type { PluginEventSubscriptionRecord } from "@codevisor/db"
import type { McpServerIdentity } from "@codevisor/mcp"

import { attribute, fromMachine } from "../../routes/session-event-messages.js"
import type { PendingSessionEvent } from "../../routes/session-event-outbox.js"
import { sourceSessionIdFor } from "./plugin-event-messages.js"

export type PluginDepartureKind = "removed" | "turnedOff"

export interface PluginDeparture {
  readonly kind: PluginDepartureKind
  readonly server: McpServerIdentity
  readonly subscriptions: ReadonlyArray<PluginEventSubscriptionRecord>
}

export interface EventMachine {
  readonly id: string
  readonly name: string
}

export const pluginDepartureEvent = (
  departure: PluginDeparture,
  machine: EventMachine
): PendingSessionEvent => ({
  message: fromMachine({ text: departureText(departure) }, machine),
  sourceSessionId: sourceSessionIdFor(departure.server.id)
})

export const turnedOffReason = (pluginName: string): string => `${pluginName} is turned off`

const departureText = (departure: PluginDeparture): string => {
  const wording = wordings[departure.kind]
  const { server } = departure
  return [
    `<codevisor-event type="${wording.type}" plugin="${attribute(server.name)}" pluginId="${attribute(server.id)}">`,
    wording.opening(server.name),
    ...departure.subscriptions.map((subscription) =>
      subscriptionLine(subscription, wording.listsIds)
    ),
    wording.closing(server.name),
    "</codevisor-event>"
  ].join("\n")
}

interface DepartureWording {
  readonly type: string
  readonly listsIds: boolean
  readonly opening: (name: string) => string
  readonly closing: (name: string) => string
}

const wordings: Record<PluginDepartureKind, DepartureWording> = {
  removed: {
    type: "plugin.removed",
    listsIds: false,
    opening: (name) =>
      `The user removed the ${name} plugin, so these subscriptions of yours were deleted and won't wake you again:`,
    closing: (name) =>
      `Tell the user which follow-ups stopped. To bring them back, ${name} has to be installed again (plugins.request_setup shows the user a card), then subscribe again with events.subscribe.`
  },
  turnedOff: {
    type: "plugin.disabled",
    listsIds: true,
    opening: (name) =>
      `The user turned off ${name}, so these subscriptions of yours are on hold and won't wake you while it's off:`,
    closing: (name) =>
      `They're kept and start again on their own when ${name} is turned back on in Settings › Plugins. Tell the user which follow-ups are on hold.`
  }
}

const subscriptionLine = (subscription: PluginEventSubscriptionRecord, listsId: boolean): string =>
  [
    `- ${subscription.eventName}: ${JSON.stringify(subscription.note ?? subscription.explained)}`,
    ...subscriptionDetails(subscription, listsId)
  ].join(", ")

const subscriptionDetails = (
  subscription: PluginEventSubscriptionRecord,
  listsId: boolean
): ReadonlyArray<string> =>
  [
    subscription.filter === undefined ? undefined : `filter ${subscription.filter}`,
    hasArguments(subscription) ? `arguments ${JSON.stringify(subscription.arguments)}` : undefined,
    subscription.accountId === undefined ? undefined : `account ${subscription.accountId}`,
    subscription.once ? "once" : undefined,
    listsId ? `subscriptionId ${subscription.id}` : undefined
  ].filter((detail): detail is string => detail !== undefined)

const hasArguments = (subscription: PluginEventSubscriptionRecord): boolean =>
  Object.keys(subscription.arguments).length > 0
