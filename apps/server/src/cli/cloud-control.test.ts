import { afterEach, describe, expect, it, vi } from "vitest"

import {
  cloudUrl,
  ensureCloudServer,
  readCloudRegistration,
  waitForCloudConnection
} from "./cloud-control.js"
import { health, makeWorld, ok, systemCat, unit } from "./support-test-support.js"

afterEach(() => vi.useRealTimers())
const port = 54321
const stateUrl = `GET ${cloudUrl(port)}`
const registered = (state?: string) => ({
  status: 200,
  body: { deviceId: "machine-1", ...(state === undefined ? {} : { state }) }
})

describe("CLI Cloud lifecycle", () => {
  it("starts the installed server when it is stopped", async () => {
    const world = makeWorld({
      exec: {
        [systemCat]: unit(port),
        "systemctl start codevisor-server.service": { code: 0, stdout: "", stderr: "" }
      },
      http: { [stateUrl]: [undefined, { status: 200, body: {} }], [health(port)]: [ok] }
    })
    expect(await ensureCloudServer(world.deps, port)).toEqual({})
    expect(world.execCalls).toContain("systemctl start codevisor-server.service")
  })

  it("reports startup and registration API failures", async () => {
    const failed = makeWorld({ exec: { [systemCat]: unit(port) } })
    await expect(ensureCloudServer(failed.deps, port)).rejects.toThrow("Could not start")
    const unavailable = makeWorld({ http: { [health(port)]: [ok] } })
    await expect(ensureCloudServer(unavailable.deps, port)).rejects.toThrow("unavailable")
    for (const response of [
      { status: 404, body: {} },
      { status: 200, body: null },
      { status: 200, body: "bad" }
    ]) {
      const world = makeWorld({ http: { [stateUrl]: [response] } })
      await expect(readCloudRegistration(world.deps, port)).rejects.toThrow(
        "Cannot read Cloud state"
      )
    }
  })

  it("does not finish login until the matching machine completes the relay handshake", async () => {
    vi.useFakeTimers()
    const world = makeWorld({
      http: { [stateUrl]: [registered("connecting"), registered("connected")] }
    })
    const deps = {
      ...world.deps,
      sleep: (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))
    }
    const done = vi.fn()
    const result = waitForCloudConnection(deps, port, "machine-1").then(done)
    await vi.advanceTimersByTimeAsync(499)
    expect(done).not.toHaveBeenCalled()
    await vi.advanceTimersByTimeAsync(1)
    await result
    expect(done).toHaveBeenCalledOnce()
  })

  it.each(["revoked", "unsupported-protocol"])("fails immediately for %s", async (state) => {
    const world = makeWorld({ http: { [stateUrl]: [registered(state)] } })
    await expect(waitForCloudConnection(world.deps, port, "machine-1")).rejects.toThrow(state)
  })

  it("rejects a lost or replaced registration", async () => {
    for (const response of [
      undefined,
      { status: 200, body: { deviceId: "another-machine", state: "connected" } }
    ]) {
      const world = makeWorld({ http: { [stateUrl]: [response] } })
      await expect(waitForCloudConnection(world.deps, port, "machine-1")).rejects.toThrow(
        "registration changed"
      )
    }
  })

  it.each(["reconnecting", undefined])(
    "reports a saved but offline registration at the deadline (%s)",
    async (state) => {
      vi.useFakeTimers()
      const world = makeWorld({ http: { [stateUrl]: [registered(state)] } })
      const deps = {
        ...world.deps,
        sleep: (ms: number) => new Promise<void>((resolve) => setTimeout(resolve, ms))
      }
      const rejected = vi.fn()
      const result = waitForCloudConnection(deps, port, "machine-1").catch(rejected)
      await vi.advanceTimersByTimeAsync(29_999)
      expect(rejected).not.toHaveBeenCalled()
      await vi.advanceTimersByTimeAsync(1)
      await result
      expect(rejected).toHaveBeenCalledWith(
        expect.objectContaining({ message: expect.stringContaining("credentials are saved") })
      )
    }
  )
})
