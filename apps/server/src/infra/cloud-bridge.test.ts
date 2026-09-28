import { existsSync, mkdtempSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import type { FetchLike } from "@codevisor/cloud-client"
import { afterEach, describe, expect, it } from "vitest"

import {
  makeCloudServerControl,
  type CloudBridge,
  type CloudBridgeOptions
} from "./cloud-bridge.js"

const dirs: string[] = []
afterEach(() => {
  for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true })
})

/// A control over a stored credential and a scripted cloud. Disconnect only
/// touches the credential file, the log, and the cloud REST transport.
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
  const options = {
    credentialsPath,
    log: (line: string) => void logs.push(line),
    fetchImpl: (url: string, init?: RequestInit) => {
      calls.push({ url, ...(init === undefined ? {} : { init }) })
      return respond(url, init)
    }
  } as unknown as CloudBridgeOptions
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
    // Bounded: logout never hangs on an unresponsive cloud.
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
    const { calls } = storedControl(async () => new Response(null, { status: 500 }))
    const existing = { deviceId: "device-1", stop: () => undefined } as unknown as CloudBridge
    const dir = mkdtempSync(join(tmpdir(), "cloud-bridge-"))
    dirs.push(dir)
    const control = makeCloudServerControl(
      { credentialsPath: join(dir, "cloud.json") } as unknown as CloudBridgeOptions,
      existing
    )

    await expect(control.connect("https://cloud.example", "session")).resolves.toBe("device-1")
    expect(calls).toEqual([])
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
