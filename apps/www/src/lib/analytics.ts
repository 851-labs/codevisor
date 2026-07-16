type InstallMethod = "curl" | "brew"
type InstallPlacement = "hero" | "footer"

type AnalyticsEvent =
  | { name: "$pageview"; properties: { pathname: string } }
  | {
      name: "www install method selected"
      properties: { method: InstallMethod; placement: InstallPlacement }
    }
  | {
      name: "www install command copied"
      properties: { method: InstallMethod; placement: InstallPlacement }
    }

const PROJECT_TOKEN =
  import.meta.env.VITE_POSTHOG_PROJECT_TOKEN ?? "phc_Bjioc2MPX8qEqgnZdfuboi4Uu268kCE3pJSkMfSJtDwi"
const API_HOST = import.meta.env.VITE_POSTHOG_HOST ?? "https://us.i.posthog.com"
const ALLOWED_EVENTS = new Set<string>([
  "$pageview",
  "www install method selected",
  "www install command copied"
])

let clientPromise: Promise<typeof import("posthog-js").default | null> | undefined

function getClient() {
  if (!import.meta.env.PROD || typeof window === "undefined") return Promise.resolve(null)

  clientPromise ??= import("posthog-js").then(({ default: posthog }) => {
    posthog.init(PROJECT_TOKEN, {
      api_host: API_HOST,
      ui_host: "https://us.posthog.com",
      autocapture: false,
      capture_pageview: false,
      capture_pageleave: false,
      capture_performance: false,
      disable_session_recording: true,
      disable_surveys: true,
      disable_product_tours: true,
      advanced_disable_decide: true,
      advanced_disable_feature_flags: true,
      advanced_disable_feature_flags_on_first_load: true,
      person_profiles: "never",
      persistence: "memory",
      disable_persistence: true,
      save_referrer: false,
      save_campaign_params: false,
      before_send: (event) => {
        if (!event || !ALLOWED_EVENTS.has(event.event)) return null

        return {
          ...event,
          properties: {
            ...event.properties,
            $current_url: `${window.location.origin}${window.location.pathname}`,
            $pathname: window.location.pathname,
            $geoip_disable: true,
            site: "www"
          }
        }
      }
    })

    return posthog
  })

  return clientPromise
}

export function captureAnalytics(event: AnalyticsEvent) {
  void getClient().then((posthog) => {
    posthog?.capture(event.name, event.properties)
  })
}

export type { InstallMethod, InstallPlacement }
