import { describe, expect, it } from "vitest"

import { boot, bridged, initialized } from "./plugin-app-bridge-test-support.js"

describe("plugin app display modes", () => {
  it("asks the native host to switch and answers with the mode it chose", async () => {
    const { api, request, toApp, toNative } = initialized()

    const switched = request(2, "ui/request-display-mode", { mode: "fullscreen" })
    api.displayModeChanged("fullscreen", "display-mode-1")

    expect(toNative).toEqual([
      { type: "displayMode", mode: "fullscreen", requestId: "display-mode-1" }
    ])
    expect((await switched).result).toEqual({ mode: "fullscreen" })
    expect(toApp[0]).toEqual({
      jsonrpc: "2.0",
      method: "ui/notifications/host-context-changed",
      params: { displayMode: "fullscreen" }
    })
  })

  it("sends the new container size once the new mode has laid out, not the old one", () => {
    const { api, elapse, layout, toApp } = initialized()

    api.displayModeChanged("fullscreen")
    layout(900, 640)
    elapse(250)
    elapse(250)

    expect(toApp.map(({ params }) => params)).toEqual([
      { displayMode: "fullscreen" },
      { containerDimensions: { width: 900, height: 640 } }
    ])
  })

  it("answers with the current mode when the native host declines", async () => {
    const { api, request, toApp } = initialized()

    const declined = request(2, "ui/request-display-mode", { mode: "fullscreen" })
    api.displayModeChanged("inline", "display-mode-1")

    expect((await declined).result).toEqual({ mode: "inline" })
    expect(toApp.filter((message) => message.method !== undefined)).toEqual([])
  })

  it("never offers a mode outside the host's or the app's list", async () => {
    const host = initialized()
    const app = initialized({}, ["inline"])
    const appless = initialized({}, "everything")
    const headless = initialized({ native: false })
    const listless = initialized({
      boot: { ...boot, hostContext: { theme: "dark", displayMode: "inline" } }
    })

    const answers = await Promise.all([
      host.request(2, "ui/request-display-mode", { mode: "pip" }),
      host.request(3, "ui/request-display-mode", { mode: "inline" }),
      app.request(2, "ui/request-display-mode", { mode: "fullscreen" }),
      headless.request(2, "ui/request-display-mode", { mode: "fullscreen" }),
      listless.request(2, "ui/request-display-mode", { mode: "fullscreen" })
    ])
    const switched = appless.request(2, "ui/request-display-mode", { mode: "fullscreen" })
    appless.api.displayModeChanged("fullscreen", "display-mode-1")

    expect(answers.map(({ result }) => result)).toEqual(
      Array.from({ length: 5 }, () => ({ mode: "inline" }))
    )
    expect((await switched).result).toEqual({ mode: "fullscreen" })
    expect([...host.toNative, ...app.toNative]).toEqual([])
  })

  it("tells the app about unsolicited mode and theme changes", () => {
    const { api, toApp } = initialized()

    api.displayModeChanged("fullscreen")
    api.displayModeChanged("pip")
    api.setTheme("light")
    api.setTheme("light")
    api.setTheme("sepia")
    api.displayModeChanged("fullscreen", 7)

    expect(toApp.map(({ params }) => params)).toEqual([
      { displayMode: "fullscreen" },
      { theme: "light" }
    ])
  })

  it("holds context changes until the app is initialized, then reports them on initialize", async () => {
    const { api, request, toApp } = bridged()

    api.setTheme("light")
    api.displayModeChanged("fullscreen")

    expect(toApp).toEqual([])
    expect((await request(1, "ui/initialize", {})).result).toMatchObject({
      hostContext: { theme: "light", displayMode: "fullscreen" }
    })
  })
})
