import type { PluginEventStored, PluginEventSubscriptionRecord } from "@codevisor/db"

import {
  attribute,
  REPORT_LIMIT,
  type SessionEventMessage
} from "../../routes/session-event-messages.js"

export interface PluginEventEnvelope {
  readonly pluginName: string
  readonly accountLabel?: string
  readonly subscription: PluginEventSubscriptionRecord
  readonly event: PluginEventStored
}

export const pluginEventMessage = (envelope: PluginEventEnvelope): SessionEventMessage => ({
  text: [
    `<codevisor-event type="plugin.event" ${headerAttributes(envelope)}>`,
    summaryLine(envelope),
    boundedPayload(envelope.event.data),
    `Full payload: events.get({ eventId: "${envelope.event.id}" }).`,
    "</codevisor-event>"
  ].join("\n")
})

export const sourceSessionIdFor = (serverId: string): string => `plugin:${serverId}`

const headerAttributes = ({
  pluginName,
  accountLabel,
  subscription,
  event
}: PluginEventEnvelope): string =>
  [
    ["plugin", pluginName],
    ["event", event.eventName],
    ["account", accountLabel],
    ["subscriptionId", subscription.id],
    ["note", subscription.note],
    ["eventId", event.id],
    ["occurredAt", event.occurredAt]
  ]
    .filter((pair): pair is [string, string] => pair[1] !== undefined)
    .map(([name, value]) => `${name}="${attribute(value)}"`)
    .join(" ")

const summaryLine = ({ pluginName, event, subscription }: PluginEventEnvelope): string =>
  `${pluginName} ${event.eventName} matched "${subscription.note ?? subscription.explained}".`

const boundedPayload = (data: unknown): string => {
  const json = JSON.stringify(data ?? null)
  if (json.length <= REPORT_LIMIT) return escapeClosing(json)
  return `${escapeClosing(json.slice(0, REPORT_LIMIT))}… (truncated)`
}

const escapeClosing = (text: string): string => text.replaceAll("</", "<\\/")
