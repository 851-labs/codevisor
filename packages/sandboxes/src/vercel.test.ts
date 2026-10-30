import { describe, expect, it } from "vitest"

import { readProfileOptions } from "./options.js"
import { readAccountValues } from "./options.js"
import { SandboxChoiceNeeded, type ExecResult } from "./provider.js"
import {
  makeVercelProvider,
  vercelAdapter,
  VERCEL_DEFINITION,
  type VercelAccount,
  type VercelClient,
  type VercelCredentials,
  type VercelSandboxInfo,
  type VercelTeam,
  type VercelUser
} from "./vercel.js"

const spec = { name: "box", tags: { owner: "device-a", machine: "m1" } }
const ok: ExecResult = { exitCode: 0, stdout: "ok", stderr: "" }
const tagged = { "codevisor-owner": "device-a", "codevisor-machine": "m1" }

const fakeVercel = (sandboxes: VercelSandboxInfo[] = []) => {
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
    stop: (name) => {
      calls.push({ stop: name })
      return Promise.resolve()
    },
    extend: (name, durationMs) => {
      calls.push({ extend: name, durationMs })
      return Promise.resolve()
    },
    remove: (name) => {
      calls.push({ remove: name })
      return Promise.resolve()
    },
    list: (tags) => {
      calls.push({ list: tags })
      return Promise.resolve(sandboxes)
    }
  }
  return { client, calls }
}

describe("Vercel Sandbox provider", () => {
  it("creates a tagged sandbox from the image with its vCPUs and a Hobby-length session", async () => {
    const { client, calls } = fakeVercel()
    const provider = makeVercelProvider(client)
    const options = readProfileOptions(VERCEL_DEFINITION, { vcpus: "8", pauseAfter: "240" })

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
          timeoutMs: 2_700_000,
          tags: tagged
        }
      }
    ])
  })

  it("falls back to 2 vCPUs when options are missing", async () => {
    const { client, calls } = fakeVercel()

    await makeVercelProvider(client).create(spec, { image: "my-repo:v1" })

    expect(calls).toEqual([
      { create: { image: "my-repo:v1", vcpus: 2, timeoutMs: 2_700_000, tags: tagged } }
    ])
  })

  it("defaults to the universal image, 2 vCPUs and pausing after 30 minutes", () => {
    expect(readProfileOptions(VERCEL_DEFINITION, {})).toEqual({
      image: "vercel/sandbox/universal",
      vcpus: "2",
      pauseAfter: "30"
    })
  })

  it("pauses by stopping, wakes by resuming, and extends the session up to a deadline", async () => {
    const { client, calls } = fakeVercel([
      {
        name: "sbx-1",
        status: "running",
        expiresAt: new Date("2026-10-26T12:45:00Z"),
        tags: tagged
      }
    ])
    const pausing = makeVercelProvider(client).pausing

    await pausing?.pause("sbx-1")
    const woken = await pausing?.wake({ providerMachineId: "sbx-1" }, spec, {})
    const covered = await pausing?.keepAlive?.("sbx-1", Date.parse("2026-10-26T12:30:00Z"))
    const extended = await pausing?.keepAlive?.("sbx-1", Date.parse("2026-10-26T13:00:00Z"))

    expect(woken).toEqual({ providerMachineId: "sbx-1", expiresAt: "2026-10-26T12:45:00.000Z" })
    expect([covered, extended]).toEqual(["2026-10-26T12:45:00.000Z", "2026-10-26T13:00:00.000Z"])
    expect(calls).toEqual([
      { stop: "sbx-1" },
      { resume: "sbx-1" },
      { extend: "sbx-1", durationMs: 900_000 }
    ])
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

const personal: VercelTeam = { id: "team_me", name: "Dylan's projects" }
const labs: VercelTeam = { id: "team_labs", name: "851 Labs" }

const fakeAccount = (teams: ReadonlyArray<VercelTeam>, user: VercelUser = {}) => {
  const tokens: string[] = []
  const projects: unknown[] = []
  const connect = (token: string): VercelAccount => {
    tokens.push(token)
    return {
      user: () => Promise.resolve(user),
      teams: () => Promise.resolve(teams),
      project: (teamId, name) => {
        projects.push({ teamId, name })
        return Promise.resolve(`prj_${teamId}`)
      }
    }
  }
  return { connect, tokens, projects }
}

describe("Vercel Sandbox adapter", () => {
  it("asks only for an access token, with the team offered when the token reaches several", () => {
    expect(VERCEL_DEFINITION.accountFields.map((field) => [field.key, field.required])).toEqual([
      ["token", true],
      ["teamId", false]
    ])
    expect(readAccountValues(VERCEL_DEFINITION, { token: "tok-1" })).toEqual({ token: "tok-1" })
  })

  it("connects with the token and the team and project found when it was saved", () => {
    const credentials: VercelCredentials[] = []
    const adapter = vercelAdapter((given) => {
      credentials.push(given)
      return fakeVercel().client
    }, fakeAccount([]).connect)

    const provider = adapter.connect({ token: "tok-1", teamId: "team_me", projectId: "prj_1" })

    expect(provider.definition).toBe(VERCEL_DEFINITION)
    expect(credentials).toEqual([{ token: "tok-1", teamId: "team_me", projectId: "prj_1" }])
  })

  it("finds the token's only team, keeps sandboxes in a codevisor-sandboxes project there and names the account by its email", async () => {
    const { client, calls } = fakeVercel()
    const credentials: VercelCredentials[] = []
    const account = fakeAccount([personal], { email: "dylan@851.sh", defaultTeamId: "team_me" })
    const adapter = vercelAdapter((given) => {
      credentials.push(given)
      return client
    }, account.connect)

    const verified = await adapter.verify?.({ token: "tok-1" })

    expect(verified).toEqual({
      identity: "dylan@851.sh",
      resolved: { teamId: "team_me", projectId: "prj_team_me" }
    })
    expect(account.tokens).toEqual(["tok-1"])
    expect(account.projects).toEqual([{ teamId: "team_me", name: "codevisor-sandboxes" }])
    expect(credentials).toEqual([{ token: "tok-1", teamId: "team_me", projectId: "prj_team_me" }])
    expect(calls).toEqual([{ list: { "codevisor-owner": "codevisor-verify" } }])
  })

  it("offers a team picker, starting on the default team, when the token reaches several", async () => {
    const account = fakeAccount([personal, labs], { defaultTeamId: "team_labs" })
    const adapter = vercelAdapter(() => fakeVercel().client, account.connect)

    const asked = await adapter.verify?.({ token: "tok-1" }).catch((cause: unknown) => cause)

    expect(asked).toBeInstanceOf(SandboxChoiceNeeded)
    expect(asked).toMatchObject({
      message:
        "This token can reach more than one Vercel team. Choose the team for your sandboxes.",
      field: {
        key: "teamId",
        label: "Team",
        type: "choice",
        required: true,
        default: "team_labs",
        choices: [
          { value: "team_me", label: "Dylan's projects" },
          { value: "team_labs", label: "851 Labs" }
        ]
      }
    })
    expect(account.projects).toEqual([])
  })

  it("leaves the picker unselected when the default team is out of the token's reach", async () => {
    const account = fakeAccount([personal, labs], { defaultTeamId: "team_other" })
    const adapter = vercelAdapter(() => fakeVercel().client, account.connect)

    const asked = await adapter.verify?.({ token: "tok-1" }).catch((cause: unknown) => cause)

    expect(asked).toBeInstanceOf(SandboxChoiceNeeded)
    expect(asked).not.toHaveProperty("field.default")
  })

  it("uses the chosen team, and finds the team again when the chosen one is out of reach", async () => {
    const several = fakeAccount([personal, labs])
    const one = fakeAccount([personal])

    const chosen = await vercelAdapter(() => fakeVercel().client, several.connect).verify?.({
      token: "tok-1",
      teamId: "team_labs"
    })
    const stale = await vercelAdapter(() => fakeVercel().client, one.connect).verify?.({
      token: "tok-2",
      teamId: "team_labs"
    })

    expect(chosen).toEqual({ resolved: { teamId: "team_labs", projectId: "prj_team_labs" } })
    expect(stale).toEqual({ resolved: { teamId: "team_me", projectId: "prj_team_me" } })
  })

  it("rejects a token that reaches no team", async () => {
    const adapter = vercelAdapter(() => fakeVercel().client, fakeAccount([]).connect)

    await expect(adapter.verify?.({ token: "tok-1" })).rejects.toThrow(
      "This token can't reach any Vercel team"
    )
  })
})

const withStatus = (name: string, status: string): VercelSandboxInfo => ({ name, status, tags: {} })
