import { makeFakeSandboxProvider, type ExecRequest } from "@codevisor/sandboxes"
import { describe, expect, it } from "vitest"

import { run } from "../server-context.js"
import { makeServices } from "../test-support.js"
import { sandboxRemote, SandboxRemoteError } from "./sandbox-remote.js"
import { ONE_WAY_SYNC_NAMESPACES, pushOneWaySync } from "./sandbox-sync.js"

const stamp = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "owner" })

const remoteOnlyEntry = { key: "remote-only", value: { from: "sandbox" }, timestamp: stamp(9) }

const recordingRemote = (answer: (request: ExecRequest) => string = () => "{}") => {
  const requests: ExecRequest[] = []
  const provider = makeFakeSandboxProvider({
    onExec: (_id, request) => {
      requests.push(request)
      return { exitCode: 0, stdout: answer(request), stderr: "" }
    }
  })
  return { requests, remote: sandboxRemote(provider, "fake-1") }
}

const urlOf = (request: ExecRequest): string => /'(http:[^']+)'$/.exec(request.script)?.[1] ?? ""

describe("one-way sync to a sandbox", () => {
  it("pushes every namespace this machine holds, then applies each plane on the sandbox", async () => {
    const { services } = await makeServices("server-owner")
    await run(
      services.db.mergeSyncEntries("mcps", [
        { key: "linear", value: { url: "x" }, timestamp: stamp(1) }
      ])
    )
    const { requests, remote } = recordingRemote(() =>
      JSON.stringify({ namespace: "mcps", entries: [remoteOnlyEntry] })
    )

    const report = await pushOneWaySync({ db: services.db }, remote)

    const puts = requests.filter((request) => request.script.includes("-X 'PUT'"))
    expect(puts.map(urlOf)).toEqual(
      ONE_WAY_SYNC_NAMESPACES.map((namespace) => `http://127.0.0.1:49361/v1/sync/${namespace}`)
    )
    expect(JSON.parse(puts[2]?.stdin ?? "{}")).toEqual({
      entries: [{ key: "linear", value: { url: "x" }, timestamp: stamp(1) }]
    })
    expect(requests.filter((request) => request.script.includes("-X 'POST'")).map(urlOf)).toEqual([
      "http://127.0.0.1:49361/v1/sync/mcps/reconcile",
      "http://127.0.0.1:49361/v1/sync/harnesses/reconcile",
      "http://127.0.0.1:49361/v1/sync/plugins/reconcile",
      "http://127.0.0.1:49361/v1/sync/credentials/reconcile",
      "http://127.0.0.1:49361/v1/sync/accounts/publish",
      "http://127.0.0.1:49361/v1/sync/skills/reconcile"
    ])
    expect(report).toEqual({ entries: 1, skillBlobs: 0, failedSteps: [] })
  })

  it("never adopts what the sandbox answers", async () => {
    const { services } = await makeServices("server-owner")
    const { remote } = recordingRemote(() =>
      JSON.stringify({ namespace: "mcps", entries: [remoteOnlyEntry] })
    )

    await pushOneWaySync({ db: services.db }, remote)

    for (const namespace of ONE_WAY_SYNC_NAMESPACES) {
      expect(await run(services.db.getSyncEntries(namespace))).toEqual([])
    }
  })

  it("uploads the skill archives the sandbox is missing and reconciles again", async () => {
    const { services } = await makeServices("server-owner")
    let reconciles = 0
    const { requests, remote } = recordingRemote((request) => {
      if (!request.script.includes("skills/reconcile")) return "{}"
      reconciles += 1
      return JSON.stringify({
        missingBlobs: reconciles === 1 ? [{ hash: "abc" }, { hash: "gone" }, 3] : []
      })
    })
    const blobs = {
      has: (id: string) => id === "abc",
      read: () => Promise.resolve(Buffer.from("tgz"))
    }

    const report = await pushOneWaySync({ db: services.db, blobs }, remote)

    const upload = requests.find((request) => request.script.startsWith("base64 -d"))
    expect(urlOf(upload ?? { script: "" })).toBe("http://127.0.0.1:49361/v1/sync/blobs/abc")
    expect(upload?.stdin).toBe(Buffer.from("tgz").toString("base64"))
    expect(reconciles).toBe(2)
    expect(report.skillBlobs).toBe(1)
  })

  it("keeps going when a plane can't be applied on the sandbox", async () => {
    const { services } = await makeServices("server-owner")
    const provider = makeFakeSandboxProvider({
      onExec: (_id, request) =>
        request.script.includes("plugins/reconcile")
          ? { exitCode: 22, stdout: "", stderr: "curl: (22) 501\n" }
          : { exitCode: 0, stdout: "", stderr: "" }
    })

    const report = await pushOneWaySync({ db: services.db }, sandboxRemote(provider, "fake-1"))

    expect(report.failedSteps).toEqual(["/v1/sync/plugins/reconcile"])
  })
})

describe("sandbox remote", () => {
  it("reports failed requests with curl's error and rejects non-JSON answers", async () => {
    const failing = makeFakeSandboxProvider({
      onExec: () => ({ exitCode: 7, stdout: "", stderr: "curl: (7) Failed to connect\n" })
    })
    const garbled = makeFakeSandboxProvider({
      onExec: () => ({ exitCode: 0, stdout: "<html>", stderr: "" })
    })

    await expect(sandboxRemote(failing, "fake-1").request("GET", "/v1/health")).rejects.toThrow(
      "GET /v1/health failed on the sandbox: curl: (7) Failed to connect"
    )
    await expect(sandboxRemote(garbled, "fake-1").request("GET", "/v1/health")).rejects.toThrow(
      SandboxRemoteError
    )
  })
})
