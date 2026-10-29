import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { FetchLike } from "@codevisor/cloud-client"
import { afterEach, describe, expect, it, vi } from "vitest"

import {
  makeCloudServerControl,
  type CloudBridge,
  type CloudBridgeOptions
} from "./cloud-bridge.js"

const dirs: string[] = []
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

const bridgeOptions = (
  options: Pick<CloudBridgeOptions, "credentialsPath"> & Partial<CloudBridgeOptions>
): CloudBridgeOptions => ({
  machineName: "test-machine",
  icon: Promise.resolve("macmini"),
  appVersion: "0.0.0-test",
  localBaseUrl: "http://127.0.0.1:1",
  env: {},
  log: () => undefined,
  ...options
})

const notUsed = async (): Promise<never> => {
  throw new Error("The cloud bridge fixture does not fake this call")
}

const storedControl = (respond: FetchLike) => {
  const dir = mkdtempSync(join(tmpdir(), "cloud-bridge-"))
  dirs.push(dir)
  const credentialsPath = join(dir, "cloud.json")
  writeFileSync(
    credentialsPath,
    JSON.stringify({
      serverUrl: "https://cloud.example",
      deviceId: "device-1",
      publicKey: "pk",
      secretKey: "sk",
      apiKey: "machine-key"
    })
  )
  const calls: Array<{ url: string; init?: RequestInit }> = []
  const logs: string[] = []
  const options = bridgeOptions({
    credentialsPath,
    log: (line: string) => void logs.push(line),
    fetchImpl: (url: string, init?: RequestInit) => {
      calls.push({ url, ...(init === undefined ? {} : { init }) })
      return respond(url, init)
    }
  })
  return { control: makeCloudServerControl(options, undefined), credentialsPath, calls, logs }
}

describe("cloud disconnect", () => {
  it("removes the machine from its account before forgetting the credential", async () => {
    const { control, credentialsPath, calls } = storedControl(() =>
      Promise.resolve(new Response('{"ok":true}'))
    )
    expect(await control.disconnect()).toEqual({ removedFromAccount: true })
    expect(calls).toHaveLength(1)
    expect(calls[0]?.url).toBe("https://cloud.example/api/machine/self")
    expect(calls[0]?.init).toMatchObject({
      method: "DELETE",
      headers: { "x-api-key": "machine-key" }
    })
    expect(calls[0]?.init?.signal).toBeInstanceOf(AbortSignal)
    expect(existsSync(credentialsPath)).toBe(false)
  })

  it("treats an already-revoked key as removed", async () => {
    const { control } = storedControl(() =>
      Promise.resolve(new Response('{"error":"invalid machine credential"}', { status: 401 }))
    )
    expect(await control.disconnect()).toEqual({ removedFromAccount: true })
  })

  it("still forgets the credential when the cloud is unreachable", async () => {
    for (const respond of [
      () => Promise.reject(new Error("network down")),
      () => Promise.reject("socket closed"),
      () => Promise.resolve(new Response("{}", { status: 503 }))
    ]) {
      const { control, credentialsPath, logs } = storedControl(respond)
      expect(await control.disconnect()).toEqual({ removedFromAccount: false })
      expect(existsSync(credentialsPath)).toBe(false)
      expect(logs.join("\n")).toContain("could not remove this machine from its account")
    }
  })

  it("has nothing to remove without a stored credential", async () => {
    const { control, credentialsPath, calls } = storedControl(() =>
      Promise.reject(new Error("unexpected"))
    )
    rmSync(credentialsPath)
    expect(await control.disconnect()).toEqual({ removedFromAccount: true })
    expect(calls).toEqual([])
  })
})

describe("cloud connect", () => {
  it("keeps an existing registration instead of provisioning another", async () => {
    const fetchImpl = vi.fn(async () => new Response(null, { status: 500 }))
    const existing: CloudBridge = {
      deviceId: "device-1",
      serverUrl: "https://cloud.example",
      managedBy: "external",
      machineName: "test-machine",
      stop: () => undefined,
      state: () => "connected",
      acceptDirect: () => undefined,
      machines: () => undefined,
      requestGateway: notUsed,
      bridgeTunnelMedia: notUsed,
      setDirectPaths: (allowed) => (allowed ? "auto" : "relay-only")
    }
    const dir = mkdtempSync(join(tmpdir(), "cloud-bridge-"))
    dirs.push(dir)
    const control = makeCloudServerControl(
      bridgeOptions({ credentialsPath: join(dir, "cloud.json"), fetchImpl }),
      existing
    )

    await expect(control.connect("https://cloud.example", "session")).resolves.toBe("device-1")
    expect(fetchImpl).not.toHaveBeenCalled()
    expect(control.setDirectPaths(true)).toBe("auto")
    expect(control.setDirectPaths(false)).toBe("relay-only")
  })

  it("has no tunnel to switch before the machine joins an account", () => {
    const { control } = storedControl(() => Promise.reject(new Error("unexpected")))
    expect(control.setDirectPaths(true)).toBeUndefined()
  })

  it("shares one registration between concurrent callers", async () => {
    let failProvision!: () => void
    const provisioning = new Promise<Response>((resolve) => {
      failProvision = () =>
        resolve(new Response(JSON.stringify({ message: "nope" }), { status: 500 }))
    })
    const { control, calls } = storedControl(() => provisioning)

    const first = control.connect("https://cloud.example", "session-a", {
      managedBy: "external",
      machineName: "Studio"
    })
    const second = control.connect("https://cloud.example", "session-b", {
      managedBy: "external",
      machineName: "Studio"
    })
    failProvision()

    const results = await Promise.allSettled([first, second])
    expect(results.map((result) => result.status)).toEqual(["rejected", "rejected"])
    expect(calls).toHaveLength(1)
  })
})
