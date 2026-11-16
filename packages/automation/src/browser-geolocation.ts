import { pageInformation, type BrowserRuntime, type PageHandle } from "./browser-cdp-engine.js"
import { withholdTabLocation } from "./browser-location-baseline.js"
import { recordOrUndefined } from "./unknown-values.js"

type CdpParams = Readonly<Record<string, unknown>>

export interface TabPosition {
  readonly latitude: number
  readonly longitude: number
  readonly accuracy: number
}

export const setTabGeolocation = async (
  runtime: BrowserRuntime,
  page: PageHandle,
  args: CdpParams
): Promise<TabPosition> => {
  if (runtime.native === true) throw new Error(paneHasNoLocation)

  const position = tabPosition(args)
  const origins = sharedOrigins(runtime, page.sessionId)
  await runtime.connection.send("Emulation.setGeolocationOverride", { ...position }, page.sessionId)
  await share(runtime, origins, originOf((await pageInformation(runtime, page)).url))
  return position
}

export const clearTabGeolocation = async (
  runtime: BrowserRuntime,
  page: PageHandle
): Promise<void> => {
  const origins = sharing.get(runtime)?.get(page.sessionId) ?? []
  sharing.get(runtime)?.delete(page.sessionId)
  if (runtime.owned) await withholdTabLocation(runtime, page.sessionId)
  else await runtime.connection.send("Emulation.clearGeolocationOverride", {}, page.sessionId)
  for (const origin of origins) await refuseLocation(runtime, origin)
}

export const observeGeolocationEvent = (
  runtime: BrowserRuntime,
  method: string,
  params: CdpParams,
  sessionId: string | undefined
): void => {
  if (method === "Target.detachedFromTarget" && typeof params.sessionId === "string")
    sharing.get(runtime)?.delete(params.sessionId)
  if (method !== "Page.frameNavigated" || sessionId === undefined) return

  const origins = sharing.get(runtime)?.get(sessionId)
  const frame = recordOrUndefined(params.frame)
  if (origins === undefined || frame === undefined || frame.parentId !== undefined) return
  void share(runtime, origins, originOf(frame.url)).catch(() => undefined)
}

const sharing = new WeakMap<BrowserRuntime, Map<string, Set<string>>>()
const defaultAccuracyMeters = 10

const paneHasNoLocation =
  "The built-in pane can't be given a location, so pages there are refused one. Run a task that needs a location in the managed browser: browser.use_backend({ backend: 'managed' })."

const sharedOrigins = (runtime: BrowserRuntime, sessionId: string): Set<string> => {
  let sessions = sharing.get(runtime)
  if (sessions === undefined) {
    sessions = new Map()
    sharing.set(runtime, sessions)
  }
  let origins = sessions.get(sessionId)
  if (origins === undefined) {
    origins = new Set()
    sessions.set(sessionId, origins)
  }
  return origins
}

const tabPosition = (args: CdpParams): TabPosition => {
  const { latitude, longitude, accuracy = defaultAccuracyMeters } = args
  if (typeof latitude !== "number" || !(latitude >= -90 && latitude <= 90))
    throw new Error("latitude must be a number from -90 to 90")
  if (typeof longitude !== "number" || !(longitude >= -180 && longitude <= 180))
    throw new Error("longitude must be a number from -180 to 180")
  if (typeof accuracy !== "number" || !(accuracy >= 0))
    throw new Error("accuracy must be a distance in metres, 0 or more")
  return { latitude, longitude, accuracy }
}

const originOf = (url: unknown): string | undefined => {
  if (typeof url !== "string" || !URL.canParse(url)) return undefined
  const { origin, protocol } = new URL(url)
  return protocol === "http:" || protocol === "https:" ? origin : undefined
}

const share = async (
  runtime: BrowserRuntime,
  origins: Set<string>,
  origin: string | undefined
): Promise<void> => {
  if (origin === undefined || origins.has(origin)) return

  await runtime.connection
    .send("Browser.grantPermissions", { permissions: ["geolocation"], origin })
    .catch(() => {
      throw new Error(
        "This browser can't be given a location by the agent; it asks its user for location access itself"
      )
    })
  origins.add(origin)
}

const refuseLocation = (runtime: BrowserRuntime, origin: string): Promise<unknown> =>
  runtime.connection
    .send("Browser.setPermission", {
      permission: { name: "geolocation" },
      setting: "denied",
      origin
    })
    .catch(() => undefined)
