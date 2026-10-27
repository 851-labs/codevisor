import { describe, expect, it } from "vitest"

import { SANDBOX_PROVIDER_CATALOG } from "./catalog.js"
import { makeE2bProvider, type E2bClient, type E2bSandboxInfo } from "./e2b.js"
import { makeModalProvider, type ModalClient, type ModalCreateRequest } from "./modal.js"
import { defaultProviderOptions } from "./options.js"
import type { ExecResult } from "./provider.js"

const spec = { name: "box", tags: { owner: "device-a", machine: "m1" } }
const ok: ExecResult = { exitCode: 0, stdout: "ok", stderr: "" }

const fakeE2b = (sandboxes: E2bSandboxInfo[] = []) => {
  const calls: unknown[] = []
  const client: E2bClient = {
    create: (template, options) => {
      calls.push({ create: template, ...options })
      const sandbox = {
        sandboxId: "sbx-1",
        endAt: new Date("2026-10-23T12:00:00Z"),
        metadata: options.metadata
      }
      sandboxes.push(sandbox)
      return Promise.resolve(sandbox)
    },
    runAsRoot: (sandboxId, script, options) => {
      calls.push({ run: sandboxId, script, ...options })
      return Promise.resolve(ok)
    },
    info: (sandboxId) =>
      Promise.resolve(sandboxes.find((sandbox) => sandbox.sandboxId === sandboxId)),
    kill: (sandboxId) => {
      calls.push({ kill: sandboxId })
      return Promise.resolve()
    },
    list: (metadata) => {
      calls.push({ list: metadata })
      return Promise.resolve(sandboxes)
    }
  }
  return { client, calls }
}

describe("E2B provider", () => {
  it("creates a tagged sandbox from the template with the timeout in milliseconds", async () => {
    const { client, calls } = fakeE2b()
    const provider = makeE2bProvider(client)

    const created = await provider.create(spec, { template: "base", timeoutMinutes: 60 })

    expect(created).toEqual({
      providerMachineId: "sbx-1",
      platform: "linux",
      expiresAt: "2026-10-23T12:00:00.000Z"
    })
    expect(calls[0]).toEqual({
      create: "base",
      timeoutMs: 3_600_000,
      metadata: { "codevisor-owner": "device-a", "codevisor-machine": "m1" }
    })
  })

  it("defaults to the base template and the Hobby plan's one hour cap", () => {
    expect(defaultProviderOptions(makeE2bProvider(fakeE2b().client))).toEqual({
      template: "base",
      timeoutMinutes: 60
    })
  })

  it("runs scripts as root with a default timeout and forwards stdin", async () => {
    const { client, calls } = fakeE2b()
    const provider = makeE2bProvider(client)

    await provider.exec("sbx-1", { script: "id" })
    await provider.exec("sbx-1", { script: "cat", stdin: "x", timeoutMs: 5 })

    expect(calls).toEqual([
      { run: "sbx-1", script: "id", timeoutMs: 600_000 },
      { run: "sbx-1", script: "cat", stdin: "x", timeoutMs: 5 }
    ])
  })

  it("reports running sandboxes with their expiry and missing ones as gone", async () => {
    const { client } = fakeE2b([{ sandboxId: "sbx-1", metadata: {} }])
    const provider = makeE2bProvider(client)

    expect(await provider.status("sbx-1")).toEqual({ state: "running" })
    expect(await provider.status("sbx-404")).toEqual({ state: "gone" })
  })

  it("lists only sandboxes carrying both Codevisor tags, filtered by owner", async () => {
    const { client, calls } = fakeE2b([
      {
        sandboxId: "sbx-1",
        metadata: { "codevisor-owner": "device-a", "codevisor-machine": "m1" }
      },
      { sandboxId: "sbx-2", metadata: { "codevisor-owner": "device-a" } }
    ])
    const provider = makeE2bProvider(client)

    expect(await provider.list("device-a")).toEqual([
      { providerMachineId: "sbx-1", tags: { owner: "device-a", machine: "m1" } }
    ])
    expect(calls).toEqual([{ list: { "codevisor-owner": "device-a" } }])
  })

  it("kills the sandbox on destroy", async () => {
    const { client, calls } = fakeE2b()

    await makeE2bProvider(client).destroy("sbx-1")

    expect(calls).toEqual([{ kill: "sbx-1" }])
  })
})

const fakeModal = (running: Record<string, boolean>) => {
  const calls: unknown[] = []
  const client: ModalClient = {
    create: (request: ModalCreateRequest) => {
      calls.push(request)
      return Promise.resolve("sb-1")
    },
    exec: (sandboxId, script, options) => {
      calls.push({ exec: sandboxId, script, ...options })
      return Promise.resolve(ok)
    },
    isRunning: (sandboxId) => Promise.resolve(running[sandboxId]),
    terminate: (sandboxId) => {
      calls.push({ terminate: sandboxId })
      return Promise.resolve()
    },
    list: (tags) => {
      calls.push({ list: tags })
      return Promise.resolve([
        { sandboxId: "sb-1", tags: { "codevisor-owner": "device-a", "codevisor-machine": "m1" } },
        { sandboxId: "sb-2", tags: {} }
      ])
    },
    snapshot: (sandboxId) => Promise.resolve(`im-${sandboxId}`)
  }
  return { client, calls }
}

describe("Modal provider", () => {
  const start = Date.parse("2026-10-23T00:00:00Z")

  it("creates a tagged sandbox and computes its expiry from the lifetime", async () => {
    const { client, calls } = fakeModal({})
    const provider = makeModalProvider(client, () => start)
    const options = defaultProviderOptions(provider)

    const created = await provider.create(spec, options)

    expect(created).toEqual({
      providerMachineId: "sb-1",
      platform: "linux",
      expiresAt: "2026-10-24T00:00:00.000Z"
    })
    expect(calls[0]).toMatchObject({
      image: "debian:bookworm-slim",
      cpu: 2,
      memoryMiB: 4096,
      timeoutMs: 86_400_000,
      tags: { "codevisor-owner": "device-a", "codevisor-machine": "m1" }
    })
    expect(calls[0]).toHaveProperty(
      ["setupCommands", 0],
      expect.stringContaining("curl ca-certificates git sudo")
    )
  })

  it("maps poll results to running, stopped and gone", async () => {
    const provider = makeModalProvider(fakeModal({ a: true, b: false }).client)

    expect(await provider.status("a")).toEqual({ state: "running" })
    expect(await provider.status("b")).toEqual({ state: "stopped" })
    expect(await provider.status("c")).toEqual({ state: "gone" })
  })

  it("execs with stdin and a default timeout, terminates, lists by owner and snapshots", async () => {
    const { client, calls } = fakeModal({})
    const provider = makeModalProvider(client)

    await provider.exec("sb-1", { script: "id" })
    await provider.exec("sb-1", { script: "cat", stdin: "x", timeoutMs: 5 })
    await provider.destroy("sb-1")
    const listed = await provider.list("device-a")
    const snapshot = await provider.snapshot?.("sb-1")

    expect(calls).toEqual([
      { exec: "sb-1", script: "id", timeoutMs: 600_000 },
      { exec: "sb-1", script: "cat", stdin: "x", timeoutMs: 5 },
      { terminate: "sb-1" },
      { list: { "codevisor-owner": "device-a" } }
    ])
    expect(listed).toEqual([
      { providerMachineId: "sb-1", tags: { owner: "device-a", machine: "m1" } }
    ])
    expect(snapshot).toEqual({ snapshotId: "im-sb-1" })
  })
})

describe("provider catalog", () => {
  it("lists every provider with the defaults a project can override", () => {
    const defaults = Object.fromEntries(
      Object.values(SANDBOX_PROVIDER_CATALOG).map((entry) => [
        entry.displayName,
        defaultProviderOptions(entry)
      ])
    )

    expect(defaults).toEqual({
      E2B: { template: "base", timeoutMinutes: 60 },
      Modal: {
        image: "debian:bookworm-slim",
        setupCommands: [expect.stringContaining("apt-get install")],
        cpu: 2,
        memoryMiB: 4096,
        timeoutMinutes: 1440
      },
      Tart: {
        baseImage: "ghcr.io/cirruslabs/macos-tahoe-base:latest",
        cpu: 4,
        memoryGiB: 8,
        minFreeDiskGiB: 40
      }
    })
  })
})
