import { describe, expect, it } from "vitest"

import { SANDBOX_PROVIDER_DEFINITIONS, sandboxDefinition } from "./catalog.js"
import {
  E2B_DEFINITION,
  e2bAdapter,
  makeE2bProvider,
  type E2bClient,
  type E2bSandboxInfo
} from "./e2b.js"
import { fieldDefaults } from "./fields.js"
import {
  makeModalProvider,
  modalAdapter,
  MODAL_DEFINITION,
  type ModalClient,
  type ModalCreateRequest
} from "./modal.js"
import { readProfileOptions } from "./options.js"
import type { ExecResult } from "./provider.js"

const spec = { name: "box", tags: { owner: "device-a", machine: "m1" } }
const start = Date.parse("2026-10-23T00:00:00Z")
const ok: ExecResult = { exitCode: 0, stdout: "ok", stderr: "" }

const fakeE2b = (sandboxes: E2bSandboxInfo[] = []) => {
  const calls: unknown[] = []
  const client: E2bClient = {
    create: (template, options) => {
      calls.push({ create: template, ...options })
      const sandbox = {
        sandboxId: "sbx-1",
        state: "running" as const,
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
    pause: (sandboxId) => {
      calls.push({ pause: sandboxId })
      return Promise.resolve()
    },
    resume: (sandboxId, timeoutMs) => {
      calls.push({ resume: sandboxId, timeoutMs })
      return Promise.resolve({
        sandboxId,
        state: "running",
        endAt: new Date(start + timeoutMs),
        metadata: {}
      })
    },
    setTimeout: (sandboxId, timeoutMs) => {
      calls.push({ setTimeout: sandboxId, timeoutMs })
      return Promise.resolve()
    },
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
  it("creates a tagged sandbox from the template with an hour the manager extends", async () => {
    const { client, calls } = fakeE2b()
    const provider = makeE2bProvider(client)

    const created = await provider.create(spec, { template: "base", pauseAfter: "30" })

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

  it("defaults to the base template and pausing after 30 minutes", () => {
    expect(readProfileOptions(E2B_DEFINITION, {})).toEqual({ template: "base", pauseAfter: "30" })
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

  it("reports running, paused and missing sandboxes", async () => {
    const { client } = fakeE2b([
      { sandboxId: "sbx-1", state: "running", metadata: {} },
      { sandboxId: "sbx-2", state: "paused", metadata: {} }
    ])
    const provider = makeE2bProvider(client)

    expect(await provider.status("sbx-1")).toEqual({ state: "running" })
    expect(await provider.status("sbx-2")).toEqual({ state: "stopped" })
    expect(await provider.status("sbx-404")).toEqual({ state: "gone" })
  })

  it("lists only sandboxes carrying both Codevisor tags, filtered by owner", async () => {
    const { client, calls } = fakeE2b([
      {
        sandboxId: "sbx-1",
        state: "running",
        metadata: { "codevisor-owner": "device-a", "codevisor-machine": "m1" }
      },
      { sandboxId: "sbx-2", state: "paused", metadata: { "codevisor-owner": "device-a" } }
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

  it("pauses in place and wakes the same sandbox for another hour", async () => {
    const { client, calls } = fakeE2b()
    const pausing = makeE2bProvider(client, () => start).pausing

    const paused = await pausing?.pause("sbx-1")
    const woken = await pausing?.wake({ providerMachineId: "sbx-1" }, spec, {})

    expect(paused).toEqual({ providerMachineId: "sbx-1" })
    expect(woken).toEqual({ providerMachineId: "sbx-1", expiresAt: "2026-10-23T01:00:00.000Z" })
    expect(calls).toEqual([{ pause: "sbx-1" }, { resume: "sbx-1", timeoutMs: 3_600_000 }])
  })

  it("keeps a sandbox alive until the deadline, an hour at a time", async () => {
    const { client, calls } = fakeE2b()
    const pausing = makeE2bProvider(client, () => start).pausing

    const soon = await pausing?.keepAlive?.("sbx-1", start + 20 * 60_000)
    const later = await pausing?.keepAlive?.("sbx-1", start + 5 * 3_600_000)

    expect([soon, later]).toEqual(["2026-10-23T00:20:00.000Z", "2026-10-23T01:00:00.000Z"])
    expect(calls).toEqual([
      { setTimeout: "sbx-1", timeoutMs: 1_200_000 },
      { setTimeout: "sbx-1", timeoutMs: 3_600_000 }
    ])
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
  it("creates a tagged sandbox that lives Modal's full 24 hours", async () => {
    const { client, calls } = fakeModal({})
    const provider = makeModalProvider(client, () => start)
    const options = readProfileOptions(MODAL_DEFINITION, {})

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

  it("pauses by snapshotting then terminating, and wakes a new sandbox from the snapshot", async () => {
    const { client, calls } = fakeModal({})
    const pausing = makeModalProvider(client, () => start).pausing
    const options = readProfileOptions(MODAL_DEFINITION, { cpu: 4 })

    const paused = await pausing?.pause("sb-1")
    const woken = paused && (await pausing?.wake(paused, spec, options))

    expect(paused).toEqual({ providerMachineId: "sb-1", snapshot: "im-sb-1" })
    expect(woken).toEqual({ providerMachineId: "sb-1", expiresAt: "2026-10-24T00:00:00.000Z" })
    expect(calls).toEqual([
      { terminate: "sb-1" },
      expect.objectContaining({ snapshot: "im-sb-1", cpu: 4, timeoutMs: 86_400_000 })
    ])
  })

  it("can't wake a sandbox without a snapshot, and offers no Never", async () => {
    const pausing = makeModalProvider(fakeModal({}).client).pausing

    await expect(pausing?.wake({ providerMachineId: "sb-1" }, spec, {})).rejects.toThrow(
      "This Modal sandbox has no snapshot to wake from"
    )
    expect(() => readProfileOptions(MODAL_DEFINITION, { pauseAfter: "never" })).toThrow(
      "Pause after must be one of 15 min, 30 min, 1 hr, 4 hr"
    )
    expect(MODAL_DEFINITION.profileFields.at(-1)).toMatchObject({
      key: "pauseAfter",
      description: "How long a sandbox stays alive without a chat running."
    })
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

describe("provider adapters", () => {
  it("connect with the account's tokens and check them with a harmless list", async () => {
    const tokens: unknown[] = []
    const e2b = e2bAdapter((apiKey) => {
      tokens.push(apiKey)
      return fakeE2b().client
    })
    const modal = modalAdapter((pair) => {
      tokens.push(pair)
      return fakeModal({}).client
    })

    expect(await e2b.verify?.({ apiKey: "e2b_1" })).toEqual({})
    expect(await modal.verify?.({ tokenId: "ak-1", tokenSecret: "as-1" })).toEqual({})
    expect(e2b.connect({ apiKey: "e2b_2" }).definition).toBe(E2B_DEFINITION)
    expect(modal.connect({ tokenId: "ak-2", tokenSecret: "as-2" }).definition).toBe(
      MODAL_DEFINITION
    )
    expect(tokens).toEqual([
      "e2b_1",
      { tokenId: "ak-1", tokenSecret: "as-1" },
      "e2b_2",
      { tokenId: "ak-2", tokenSecret: "as-2" }
    ])
  })
})

describe("provider catalog", () => {
  it("lists each provider's profile defaults and keeps its tokens secret", () => {
    const summary = Object.fromEntries(
      SANDBOX_PROVIDER_DEFINITIONS.map((definition) => [
        definition.displayName,
        {
          defaults: fieldDefaults(definition.profileFields),
          secrets: definition.accountFields.filter((field) => field.type === "secret").length
        }
      ])
    )

    expect(summary).toEqual({
      Tart: {
        defaults: { image: "ghcr.io/cirruslabs/macos-tahoe-base:latest", cpu: 2, memoryGiB: 4 },
        secrets: 0
      },
      "Apple Containers": {
        defaults: { image: "docker.io/library/debian:bookworm-slim", cpu: 2, memoryGiB: 4 },
        secrets: 0
      },
      "Tart Orchard": {
        defaults: {
          image: "ghcr.io/cirruslabs/macos-tahoe-base:latest",
          cpu: 4,
          memoryGiB: 8,
          username: "admin",
          password: "admin"
        },
        secrets: 1
      },
      E2B: { defaults: { template: "base", pauseAfter: "30" }, secrets: 1 },
      Modal: {
        defaults: { image: "debian:bookworm-slim", cpu: 2, memoryGiB: 4, pauseAfter: "30" },
        secrets: 1
      },
      "Vercel Sandbox": {
        defaults: { image: "vercel/sandbox/universal", vcpus: "2", pauseAfter: "30" },
        secrets: 1
      },
      Daytona: {
        defaults: {
          image: "debian:bookworm-slim",
          cpu: 2,
          memoryGiB: 4,
          diskGiB: 10,
          pauseAfter: "30"
        },
        secrets: 1
      }
    })
    expect(sandboxDefinition("e2b")).toBe(E2B_DEFINITION)
  })
})
