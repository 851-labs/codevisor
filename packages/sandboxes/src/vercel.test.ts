import { describe, expect, it } from "vitest"

import { readProfileOptions } from "./options.js"
import type { ExecResult } from "./provider.js"
import {
  makeVercelProvider,
  vercelAdapter,
  VERCEL_DEFINITION,
  type VercelClient,
  type VercelCredentials,
  type VercelSandboxInfo
} from "./vercel.js"

const spec = { name: "box", tags: { owner: "device-a", machine: "m1" } }
const ok: ExecResult = { exitCode: 0, stdout: "ok", stderr: "" }
const tagged = { "codevisor-owner": "device-a", "codevisor-machine": "m1" }

const fakeVercel = (sandboxes: VercelSandboxInfo[] = [], email?: string) => {
  const calls: unknown[] = []
  const client: VercelClient = {
    create: (request) => {
      calls.push({ create: request })
      const sandbox: VercelSandboxInfo = {
        name: "sbx-1",
        status: "running",
        expiresAt: new Date("2026-10-26T12:45:00Z"),
        tags: request.tags
      }
      sandboxes.push(sandbox)
      return Promise.resolve(sandbox)
    },
    runAsRoot: (name, script, options) => {
      calls.push({ run: name, script, ...options })
      return Promise.resolve(ok)
    },
    info: (name) => Promise.resolve(sandboxes.find((sandbox) => sandbox.name === name)),
    resume: (name) => {
      calls.push({ resume: name })
      return Promise.resolve()
    },
    remove: (name) => {
      calls.push({ remove: name })
      return Promise.resolve()
    },
    list: (tags) => {
      calls.push({ list: tags })
      return Promise.resolve(sandboxes)
    },
    email: () => Promise.resolve(email)
  }
  return { client, calls }
}

describe("Vercel Sandbox provider", () => {
  it("creates a tagged sandbox from the image with its vCPUs and session length", async () => {
    const { client, calls } = fakeVercel()
    const provider = makeVercelProvider(client)
    const options = readProfileOptions(VERCEL_DEFINITION, { vcpus: "8", timeoutMinutes: 1440 })

    const created = await provider.create(spec, options)

    expect(created).toEqual({
      providerMachineId: "sbx-1",
      platform: "linux",
      expiresAt: "2026-10-26T12:45:00.000Z"
    })
    expect(calls).toEqual([
      {
        create: {
          image: "vercel/sandbox/universal",
          vcpus: 8,
          timeoutMs: 86_400_000,
          tags: tagged
        }
      }
    ])
  })

  it("falls back to 2 vCPUs and the Hobby session cap when options are missing", async () => {
    const { client, calls } = fakeVercel()

    await makeVercelProvider(client).create(spec, { image: "my-repo:v1" })

    expect(calls).toEqual([
      { create: { image: "my-repo:v1", vcpus: 2, timeoutMs: 2_700_000, tags: tagged } }
    ])
  })

  it("defaults to the universal image, 2 vCPUs and a 45 minute session", () => {
    expect(readProfileOptions(VERCEL_DEFINITION, {})).toEqual({
      image: "vercel/sandbox/universal",
      vcpus: "2",
      timeoutMinutes: 45
    })
  })

  it("offers the vCPU counts Vercel documents, each with 2 GB of memory per vCPU", () => {
    const vcpus = VERCEL_DEFINITION.profileFields.find((field) => field.key === "vcpus")

    expect(vcpus?.choices).toEqual([
      { value: "1", label: "1 vCPU · 2 GB" },
      { value: "2", label: "2 vCPUs · 4 GB" },
      { value: "4", label: "4 vCPUs · 8 GB" },
      { value: "8", label: "8 vCPUs · 16 GB" },
      { value: "16", label: "16 vCPUs · 32 GB" },
      { value: "32", label: "32 vCPUs · 64 GB" }
    ])
    expect(() => readProfileOptions(VERCEL_DEFINITION, { vcpus: "3" })).toThrow(
      "vCPUs must be one of"
    )
    expect(() => readProfileOptions(VERCEL_DEFINITION, { timeoutMinutes: 1441 })).toThrow(
      "Session length (minutes) must be between 1 and 1440"
    )
  })

  it("runs scripts as root with a default timeout and forwards stdin", async () => {
    const { client, calls } = fakeVercel()
    const provider = makeVercelProvider(client)

    await provider.exec("sbx-1", { script: "id" })
    await provider.exec("sbx-1", { script: "cat", stdin: "x", timeoutMs: 5 })

    expect(calls).toEqual([
      { run: "sbx-1", script: "id", timeoutMs: 600_000 },
      { run: "sbx-1", script: "cat", stdin: "x", timeoutMs: 5 }
    ])
  })

  it("maps session statuses so stopped sandboxes resume and only failed or missing ones are gone", async () => {
    const at = new Date("2026-10-26T13:00:00Z")
    const { client } = fakeVercel([
      { ...withStatus("running", "running"), expiresAt: at },
      withStatus("pending", "pending"),
      withStatus("stopping", "stopping"),
      withStatus("snapshotting", "snapshotting"),
      withStatus("stopped", "stopped"),
      withStatus("failed", "failed"),
      withStatus("aborted", "aborted"),
      withStatus("future", "hibernating")
    ])
    const provider = makeVercelProvider(client)
    const names = [
      "running",
      "pending",
      "stopping",
      "snapshotting",
      "stopped",
      "failed",
      "aborted",
      "future",
      "missing"
    ]

    const statuses = await Promise.all(names.map((name) => provider.status(name)))

    expect(Object.fromEntries(names.map((name, index) => [name, statuses[index]]))).toEqual({
      running: { state: "running", expiresAt: "2026-10-26T13:00:00.000Z" },
      pending: { state: "starting" },
      stopping: { state: "starting" },
      snapshotting: { state: "starting" },
      stopped: { state: "stopped" },
      failed: { state: "gone" },
      aborted: { state: "gone" },
      future: { state: "starting" },
      missing: { state: "gone" }
    })
  })

  it("lists only sandboxes carrying both Codevisor tags, filtered by owner", async () => {
    const { client, calls } = fakeVercel([
      { name: "sbx-1", status: "running", tags: tagged },
      { name: "sbx-2", status: "stopped", tags: { "codevisor-owner": "device-a" } }
    ])

    const listed = await makeVercelProvider(client).list("device-a")

    expect(listed).toEqual([
      { providerMachineId: "sbx-1", tags: { owner: "device-a", machine: "m1" } }
    ])
    expect(calls).toEqual([{ list: { "codevisor-owner": "device-a" } }])
  })

  it("resumes and deletes sandboxes by name", async () => {
    const { client, calls } = fakeVercel()
    const provider = makeVercelProvider(client)

    await provider.resume?.("sbx-1")
    await provider.destroy("sbx-1")

    expect(calls).toEqual([{ resume: "sbx-1" }, { remove: "sbx-1" }])
  })
})

describe("Vercel Sandbox adapter", () => {
  const account = { token: "tok-1", teamId: "team_1", projectId: "prj_1" }

  it("connects with the token, team and project", () => {
    const credentials: VercelCredentials[] = []
    const adapter = vercelAdapter((given) => {
      credentials.push(given)
      return fakeVercel().client
    })

    expect(adapter.connect(account).definition).toBe(VERCEL_DEFINITION)
    expect(credentials).toEqual([account])
  })

  it("verifies with a harmless list and names the account by its email", async () => {
    const { client, calls } = fakeVercel([], "dylan@851.sh")

    const identity = await vercelAdapter(() => client).verify?.(account)

    expect(identity).toEqual({ identity: "dylan@851.sh" })
    expect(calls).toEqual([{ list: { "codevisor-owner": "codevisor-verify" } }])
  })

  it("verifies without an identity when the token cannot read the user", async () => {
    const identity = await vercelAdapter(() => fakeVercel().client).verify?.(account)

    expect(identity).toEqual({})
  })
})

const withStatus = (name: string, status: string): VercelSandboxInfo => ({ name, status, tags: {} })
