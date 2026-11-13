import type { CreatePluginEventSubscriptionRequest, PluginEventType } from "@codevisor/api"

import type { EventOccurrence } from "./plugin-event-ingest.js"
import type { EventSource } from "./plugin-event-source-key.js"

export interface BuiltinEventSource {
  readonly plugin: string
  readonly pluginName: string
  readonly symbolName: string
  readonly types: ReadonlyArray<PluginEventType>
  readonly prepare: (request: CreatePluginEventSubscriptionRequest) => PreparedSubscription
  readonly run: (source: EventSource, run: BuiltinSourceRun) => Promise<number>
  readonly display: (source: EventSource) => SubscriptionDisplay
}

export interface SubscriptionDisplay {
  readonly label: string
  readonly firesAt?: string
}

export interface PreparedSubscription {
  readonly request: CreatePluginEventSubscriptionRequest
  readonly explained?: string
}

export interface BuiltinSourceRun {
  readonly cursor: () => Promise<string | undefined>
  readonly saveCursor: (cursor: string) => Promise<void>
  readonly ingest: (occurrences: ReadonlyArray<EventOccurrence>) => Promise<number>
}

export interface BuiltinEventSources {
  readonly types: ReadonlyArray<PluginEventType>
  readonly owner: (plugin: string) => BuiltinEventSource | undefined
}

export const builtinEventSources = (
  sources: ReadonlyArray<BuiltinEventSource>
): BuiltinEventSources => ({
  types: sources.flatMap((source) => source.types),
  owner: (plugin) => sources.find((source) => source.plugin === plugin)
})

export const noBuiltinEventSources: BuiltinEventSources = builtinEventSources([])
