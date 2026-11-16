import { describe, expect, it } from "vitest"

import type { PageHandle } from "./browser-cdp-engine.js"
import {
  clearTabGeolocation,
  observeGeolocationEvent,
  setTabGeolocation
} from "./browser-geolocation.js"
import { fakeBrowserRuntime, fakeCdpConnection } from "./browser-runtime-test-support.js"

const page: PageHandle = {
  target: { targetId: "tab", type: "page", title: "", url: "https://maps.test/" },
  sessionId: "session"
}
const paris = { latitude: 48.8584, longitude: 2.2945 }

const fixture = (browser: { owned?: boolean; native?: boolean; grants?: boolean } = {}) => {
  const sent: Array<readonly [string, unknown, string | undefined]> = []
  let granted: (() => void) | undefined
  const runtime = fakeBrowserRuntime({
    owned: browser.owned ?? true,
    ...(browser.native === true ? { native: true } : {}),
    connection: fakeCdpConnection({
      send: async (method, params, sessionId) => {
        sent.push([method, params, sessionId])
        if (method === "Runtime.evaluate")
          return { result: { value: { url: "https://maps.test/search?q=cafe", title: "Maps" } } }
        if (method === "Browser.grantPermissions") {
          if (browser.grants === false) throw new Error("Not allowed")
          granted?.()
        }
        return {}
      }
    }).connection
  })
  const nextGrant = () =>
    new Promise<void>((resolve) => {
      granted = resolve
    })
  const commands = () => sent.filter(([method]) => method !== "Runtime.evaluate")
  return { runtime, sent, commands, nextGrant }
}

const grantFor = (origin: string) =>
  ["Browser.grantPermissions", { permissions: ["geolocation"], origin }, undefined] as const

const refused = (origin: string) => [
  "Browser.setPermission",
  { permission: { name: "geolocation" }, setting: "denied", origin },
  undefined
]

describe("Tab location", () => {
  it("gives the tab the position and lets the page's site read it", async () => {
    const { runtime, commands } = fixture()
    expect(await setTabGeolocation(runtime, page, paris)).toEqual({ ...paris, accuracy: 10 })
    expect(commands()).toEqual([
      ["Emulation.setGeolocationOverride", { ...paris, accuracy: 10 }, "session"],
      grantFor("https://maps.test")
    ])
  })

  it("follows the tab to each new site, once, and ignores frames and other tabs", async () => {
    const { runtime, commands, nextGrant, sent } = fixture()
    await setTabGeolocation(runtime, page, paris)
    sent.length = 0

    const navigate = (frame: Record<string, unknown>, sessionId = "session") => {
      observeGeolocationEvent(runtime, "Page.frameNavigated", { frame }, sessionId)
    }
    navigate({ id: "main", url: "https://maps.test/place" })
    navigate({ id: "ad", parentId: "main", url: "https://ads.test/" })
    navigate({ id: "main", url: "https://elsewhere.test/" }, "other-session")
    navigate({ id: "main", url: "about:blank" })
    const granted = nextGrant()
    navigate({ id: "main", url: "https://shop.test/stores" })
    await granted
    expect(commands()).toEqual([grantFor("https://shop.test")])
  })

  it("takes the location back from every site it was shared with", async () => {
    const { runtime, commands, nextGrant, sent } = fixture()
    await setTabGeolocation(runtime, page, paris)
    const granted = nextGrant()
    observeGeolocationEvent(
      runtime,
      "Page.frameNavigated",
      { frame: { id: "main", url: "https://shop.test/" } },
      "session"
    )
    await granted
    sent.length = 0

    await clearTabGeolocation(runtime, page)
    expect(commands()).toEqual([
      ["Emulation.setGeolocationOverride", {}, "session"],
      refused("https://maps.test"),
      refused("https://shop.test")
    ])

    sent.length = 0
    observeGeolocationEvent(
      runtime,
      "Page.frameNavigated",
      { frame: { id: "main", url: "https://later.test/" } },
      "session"
    )
    await clearTabGeolocation(runtime, page)
    expect(commands()).toEqual([["Emulation.setGeolocationOverride", {}, "session"]])
  })

  it("removes only its own override in a browser that belongs to the user", async () => {
    const { runtime, commands } = fixture({ owned: false })
    await clearTabGeolocation(runtime, page)
    expect(commands()).toEqual([["Emulation.clearGeolocationOverride", {}, "session"]])
  })

  it("says the built-in pane can't be given a location, and sends nothing", async () => {
    const { runtime, sent } = fixture({ owned: false, native: true })
    await expect(setTabGeolocation(runtime, page, paris)).rejects.toThrow(
      "The built-in pane can't be given a location"
    )
    expect(sent).toEqual([])
  })

  it("says so when the browser won't take a grant from the agent", async () => {
    const { runtime } = fixture({ owned: false, grants: false })
    await expect(setTabGeolocation(runtime, page, paris)).rejects.toThrow(
      "This browser can't be given a location by the agent"
    )
  })

  it.each([
    [{ latitude: 91, longitude: 0 }, "latitude must be a number from -90 to 90"],
    [{ latitude: "48", longitude: 0 }, "latitude must be a number from -90 to 90"],
    [{ latitude: 0, longitude: -181 }, "longitude must be a number from -180 to 180"],
    [{ latitude: 0, longitude: 0, accuracy: -1 }, "accuracy must be a distance in metres"]
  ])("rejects the position %j", async (position, message) => {
    const { runtime, sent } = fixture()
    await expect(setTabGeolocation(runtime, page, position)).rejects.toThrow(message)
    expect(sent).toEqual([])
  })
})
