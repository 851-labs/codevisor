import {
  flagTagPrefix,
  telemetryContext,
  type TelemetrySettings
} from "../telemetry/telemetry-settings.js"
import type { PostHogEvent, SendPostHogEvent } from "./posthog-transport.js"

export type ServerAnalyticsEvent =
  | {
      readonly name: "sub agent created"
      readonly properties: {
        readonly harness_id: string
        readonly by_bot: boolean
        readonly other_machine: boolean
        readonly uses_worktree: boolean
      }
    }
  | {
      readonly name: "agent layout changed"
      readonly properties: { readonly action: string; readonly in_bot: boolean }
    }

export interface ServerAnalyticsOptions {
  readonly settings: TelemetrySettings
  readonly send: SendPostHogEvent
  readonly distinctId: string
  readonly properties: Readonly<Record<string, string | boolean>>
  readonly now?: () => Date
}

export interface ServerAnalytics {
  readonly capture: (event: ServerAnalyticsEvent) => Promise<void>
}

export const makeServerAnalytics = (options: ServerAnalyticsOptions): ServerAnalytics => {
  const now = options.now ?? (() => new Date())
  const deliver = async (event: ServerAnalyticsEvent): Promise<void> => {
    if (!(await options.settings.enabled())) return

    const context = await contextProperties(options.settings)
    await options.send(postHogEvent(event, options, context, now()))
  }
  return { capture: (event) => deliver(event).catch(() => undefined) }
}

export const installServerAnalytics = (analytics: ServerAnalytics | undefined): void => {
  installed = analytics
}

export const serverAnalyticsInstalled = (): boolean => installed !== undefined

export const captureServerEvent = (event: ServerAnalyticsEvent): void => {
  void installed?.capture(event)
}

let installed: ServerAnalytics | undefined

const postHogEvent = (
  event: ServerAnalyticsEvent,
  options: ServerAnalyticsOptions,
  context: Readonly<Record<string, unknown>>,
  timestamp: Date
): PostHogEvent => ({
  event: event.name,
  distinct_id: options.distinctId,
  timestamp: timestamp.toISOString(),
  properties: {
    ...options.properties,
    ...context,
    ...event.properties,
    $process_person_profile: false,
    $geoip_disable: true
  }
})

const contextProperties = async (
  settings: TelemetrySettings
): Promise<Readonly<Record<string, unknown>>> => {
  const context = await telemetryContext(settings)
  return {
    update_channel: context.updateChannel,
    feature_flags: context.flags,
    ...Object.fromEntries(context.flags.map((flag) => [`${flagTagPrefix}${flag}`, true]))
  }
}
