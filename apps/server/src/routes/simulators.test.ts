import type { SimulatorChrome, SimulatorDeviceTypeDetail } from "@codevisor/api"
import { describe, expect, it, vi } from "vitest"

import { SimulatorCommandError, SimulatorRequestError, type Simulators } from "../simulators.js"
import { jsonRequest, makeServices, runningServers, startWithApp } from "../test-support.js"

const udid = "8C2D33A1-7E5B-4F0A-9C3D-2B1E4F6A7D90"
const deviceType: SimulatorDeviceTypeDetail = {
  identifier: "phone",
  name: "iPhone 17",
  productFamily: "iPhone",
  features: [],
  displays: []
}
const chrome: SimulatorChrome = { identifier: "chrome", definition: {}, images: {} }

/// Simulators that answer every call, so each route can be driven over HTTP.
const fakeSimulators = (overrides: Partial<Simulators> = {}): Simulators => ({
  available: async () => true,
  list: async () => ({ devices: [], deviceTypes: [], runtimes: [] }),
  deviceType: vi.fn(async () => deviceType),
  chrome: vi.fn(async () => chrome),
  perform: vi.fn(async () => {}),
  create: vi.fn(async () => udid),
  rename: vi.fn(async () => {}),
  settings: vi.fn(async () => ({ location: "none" as const })),
  changeSettings: vi.fn(async () => ({ appearance: "dark" as const, location: "none" as const })),
  screenshot: vi.fn(async () => Buffer.from("png bytes")),
  ...overrides
})

const serve = async (simulators: Simulators) => {
  const { services } = await makeServices()
  const server = await startWithApp(services, undefined, {
    simulators,
    screenSharing: async () => ({})
  })
  runningServers.push(server)
  return server
}

const post = (body: unknown): RequestInit => ({ method: "POST", body: JSON.stringify(body) })

describe("simulator routes", () => {
  it("answers each simulator request from the Mac's simulators", async () => {
    const simulators = fakeSimulators()
    const server = await serve(simulators)
    expect(await jsonRequest(server, "/v1/simulators/device-type?identifier=phone")).toEqual({
      status: 200,
      body: deviceType
    })
    expect(await jsonRequest(server, "/v1/simulators/chrome?identifier=chrome")).toEqual({
      status: 200,
      body: chrome
    })
    const created = await jsonRequest(
      server,
      "/v1/simulators/devices",
      post({ name: "Phone", deviceTypeIdentifier: "phone", runtimeIdentifier: "ios" })
    )
    expect(created).toEqual({ status: 201, body: { udid } })
    expect(simulators.create).toHaveBeenCalledWith("Phone", "phone", "ios")
    expect(
      (
        await jsonRequest(
          server,
          "/v1/simulators/devices/action",
          post({ udid, action: "restart" })
        )
      ).status
    ).toBe(200)
    expect(simulators.perform).toHaveBeenCalledWith(udid, "restart")
    expect(
      (await jsonRequest(server, "/v1/simulators/devices/rename", post({ udid, name: "Work" })))
        .status
    ).toBe(200)
    expect(simulators.rename).toHaveBeenCalledWith(udid, "Work")
    expect(await jsonRequest(server, `/v1/simulators/settings?udid=${udid}`)).toEqual({
      status: 200,
      body: { location: "none" }
    })
    expect(
      await jsonRequest(server, "/v1/simulators/settings", post({ udid, appearance: "dark" }))
    ).toEqual({ status: 200, body: { appearance: "dark", location: "none" } })
    expect(simulators.changeSettings).toHaveBeenCalledWith({ udid, appearance: "dark" })

    const screenshot = await fetch(`${server.url}/v1/simulators/screenshot?udid=${udid}`)
    expect(screenshot.status).toBe(200)
    expect(screenshot.headers.get("content-type")).toBe("image/png")
    expect(screenshot.headers.get("cache-control")).toBe("no-store")
    expect(Buffer.from(await screenshot.arrayBuffer()).toString("utf8")).toBe("png bytes")
  })

  it("refuses websites, missing parameters and unknown routes", async () => {
    const server = await serve(fakeSimulators())
    const website = await jsonRequest(server, "/v1/simulators", {
      headers: { Origin: "https://example.com" }
    })
    expect(website.status).toBe(403)
    const fetched = await jsonRequest(server, "/v1/simulators", {
      headers: { "Sec-Fetch-Site": "cross-site" }
    })
    expect(fetched.status).toBe(403)
    expect((await jsonRequest(server, "/v1/simulators/device-type")).status).toBe(400)
    expect((await jsonRequest(server, "/v1/simulators/chrome?identifier=")).status).toBe(400)
    expect((await jsonRequest(server, "/v1/simulators/teleport")).status).toBe(404)
    // Only /v1/simulators and paths under it belong to these routes.
    expect((await jsonRequest(server, "/v1/simulatorsx")).status).toBe(404)
  })

  it("reports a bad request, a failed command and anything else as such", async () => {
    const server = await serve(
      fakeSimulators({
        settings: async () => {
          throw new SimulatorRequestError(404, "Simulator not found")
        },
        screenshot: async () => {
          throw new SimulatorCommandError("No devices are booted.")
        },
        deviceType: async () => {
          throw new Error("plutil crashed")
        }
      })
    )
    expect(await jsonRequest(server, `/v1/simulators/settings?udid=${udid}`)).toMatchObject({
      status: 404,
      body: { error: "Simulator not found" }
    })
    expect(await jsonRequest(server, `/v1/simulators/screenshot?udid=${udid}`)).toMatchObject({
      status: 502,
      body: { error: "No devices are booted." }
    })
    expect((await jsonRequest(server, "/v1/simulators/device-type?identifier=phone")).status).toBe(
      500
    )
  })
})
