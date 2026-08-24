import { describe, expect, it } from "vitest"
import {
  pluginRestoreCommand,
  pluginSetEnabledCommand,
  pluginUpdateCommand,
  pluginUpdatesCommand,
  type PluginsCliDeps
} from "./plugins.js"

interface FakeWorld {
  readonly deps: PluginsCliDeps
  readonly logs: string[]
  readonly errors: string[]
  readonly requests: Array<{ key: string; body?: unknown; timeoutMs?: number }>
  readonly confirms: string[]
}

type Response = { readonly status: number; readonly body?: unknown } | undefined

const makeWorld = (
  http: Record<string, ReadonlyArray<Response>> = {},
  confirmAnswer = true
): FakeWorld => {
  const logs: string[] = []
  const errors: string[] = []
  const requests: Array<{ key: string; body?: unknown; timeoutMs?: number }> = []
  const confirms: string[] = []
  const counts = new Map<string, number>()
  const deps: PluginsCliDeps = {
    confirm: (message) => {
      confirms.push(message)
      return Promise.resolve(confirmAnswer)
    },
    dataDir: "/tmp/data",
    env: { CODEVISOR_PORT: "49361" },
    error: (line) => errors.push(line),
    exec: () => Promise.resolve({ code: 1, stderr: "", stdout: "" }),
    execInteractive: () => Promise.resolve(0),
    fetchJson: (url, init) => {
      const key = `${init?.method ?? "GET"} ${url}`
      requests.push({
        key,
        ...(init?.body === undefined ? {} : { body: init.body }),
        ...(init?.timeoutMs === undefined ? {} : { timeoutMs: init.timeoutMs })
      })
      const responses = http[key] ?? [undefined]
      const index = counts.get(key) ?? 0
      counts.set(key, index + 1)
      const response = responses[Math.min(index, responses.length - 1)]
      return Promise.resolve(
        response === undefined ? undefined : { body: response.body, status: response.status }
      )
    },
    installedVersion: () => undefined,
    isRoot: false,
    log: (line) => logs.push(line),
    logsDir: "/tmp/logs",
    processAlive: () => false,
    readTextFile: () => undefined,
    removeFile: () => undefined,
    signal: () => false,
    sleep: () => Promise.resolve(),
    spawnDetachedServer: () => Promise.resolve(1),
    writeTextFile: () => undefined
  }
  return { confirms, deps, errors, logs, requests }
}

const UPDATES = "GET http://127.0.0.1:49361/v1/plugins/updates"
const PREPARE = "POST http://127.0.0.1:49361/v1/plugins/acme.git-diff%2Fsafe/update/prepare"
const APPLY = "POST http://127.0.0.1:49361/v1/plugins/acme.git-diff%2Fsafe/update/apply"
const RESTORE = "POST http://127.0.0.1:49361/v1/plugins/acme.git-diff%2Fsafe/restore"
const SET_ENABLED = "POST http://127.0.0.1:49361/v1/plugins/acme.git-diff%2Fsafe/set-enabled"

const plan = {
  candidate: {
    requirements: {
      executables: [
        { helpUrl: "https://nodejs.org", installHint: "Install Node.js", name: "node" },
        { name: "git" }
      ]
    },
    runCommand: "node server.js --port $PORT",
    setupCommands: ["npm ci", "npm run build"],
    version: "2.0.0"
  },
  current: {
    runCommand: "node server.js",
    setupCommands: [],
    version: "1.0.0"
  },
  name: "Git Diff",
  paneChanges: { added: ["history"], changed: ["diff"], removed: ["legacy"] },
  planId: "plan-1",
  pluginId: "acme.git-diff/safe",
  resolvedCommit: "0123456789012345678901234567890123456789",
  toolChanges: { added: [], changed: [], removed: [] }
}

describe("codevisor plugin updates", () => {
  it("prints every explicit update state with available context", async () => {
    const world = makeWorld({
      [UPDATES]: [
        {
          body: {
            updates: [
              {
                installedVersion: "1.0.0",
                pluginId: "acme.git-diff",
                registryVersion: "2.0.0",
                state: "available"
              },
              {
                installedVersion: "0.1.0",
                pluginId: "local.dev",
                reason: "Linked plugins are pinned",
                state: "pinned"
              }
            ]
          },
          status: 200
        }
      ]
    })
    expect(await pluginUpdatesCommand(world.deps)).toBe(0)
    expect(world.logs).toEqual([
      "acme.git-diff  1.0.0 -> 2.0.0  available",
      "local.dev  0.1.0  pinned — Linked plugins are pinned"
    ])
  })

  it("handles empty, failed, and unreachable update checks", async () => {
    const empty = makeWorld({ [UPDATES]: [{ body: {}, status: 200 }] })
    expect(await pluginUpdatesCommand(empty.deps)).toBe(0)
    expect(empty.logs).toEqual(["No plugin updates to report."])

    const failed = makeWorld({ [UPDATES]: [{ body: {}, status: 500 }] })
    expect(await pluginUpdatesCommand(failed.deps)).toBe(1)
    expect(failed.errors).toEqual(["Checking plugin updates failed (status 500)"])

    const down = makeWorld()
    expect(await pluginUpdatesCommand(down.deps)).toBe(1)
    expect(down.errors[0]).toContain("not running")
  })
})

describe("codevisor plugin update", () => {
  it("shows the exact prepared plan and applies that plan after consent", async () => {
    const world = makeWorld({
      [APPLY]: [{ body: { id: "acme.git-diff/safe", version: "2.0.0" }, status: 200 }],
      [PREPARE]: [{ body: plan, status: 201 }]
    })
    expect(await pluginUpdateCommand(world.deps, { pluginId: "acme.git-diff/safe" })).toBe(0)
    expect(world.confirms).toEqual(["Update Git Diff to 2.0.0?"])
    expect(world.requests[0]?.timeoutMs).toBe(600_000)
    expect(world.requests[1]).toMatchObject({ body: { planId: "plan-1" }, key: APPLY })
    const output = world.logs.join("\n")
    expect(output).toContain("Git Diff 1.0.0 -> 2.0.0")
    expect(output).toContain("commit:  0123456789012345678901234567890123456789")
    expect(output).toContain("current setup: (none)")
    expect(output).toContain("update  setup: npm ci")
    expect(output).toContain("Install Node.js")
    expect(output).toContain("https://nodejs.org")
    expect(output).toContain("pane: + history")
    expect(output).toContain("pane: ~ diff")
    expect(output).toContain("pane: - legacy")
    expect(output).toContain("tool: (none)")
    expect(output).toContain("Updated acme.git-diff/safe 2.0.0")
  })

  it("can cancel a minimal plan without applying it", async () => {
    const minimal = {
      ...plan,
      candidate: { runCommand: "./serve", setupCommands: [], version: "2.0.0" },
      paneChanges: { added: [], changed: [], removed: [] }
    }
    const world = makeWorld({ [PREPARE]: [{ body: minimal, status: 201 }] }, false)
    expect(await pluginUpdateCommand(world.deps, { pluginId: "acme.git-diff/safe" })).toBe(1)
    expect(world.logs.join("\n")).toContain("(none declared)")
    expect(world.logs.join("\n")).toContain("pane: (none)")
    expect(world.logs.at(-1)).toBe("Cancelled.")
    expect(world.requests).toHaveLength(1)
  })

  it("supports --yes and reports prepare/apply transport failures", async () => {
    const yes = makeWorld({
      [APPLY]: [{ body: { id: "acme.git-diff/safe" }, status: 200 }],
      [PREPARE]: [{ body: plan, status: 201 }]
    })
    expect(await pluginUpdateCommand(yes.deps, { pluginId: "acme.git-diff/safe", yes: true })).toBe(
      0
    )
    expect(yes.confirms).toEqual([])
    expect(yes.logs.at(-1)).toBe("Updated acme.git-diff/safe")

    const prepareRejected = makeWorld({
      [PREPARE]: [{ body: { error: "No compatible update" }, status: 409 }]
    })
    expect(
      await pluginUpdateCommand(prepareRejected.deps, { pluginId: "acme.git-diff/safe" })
    ).toBe(1)
    expect(prepareRejected.errors).toEqual(["No compatible update"])

    const prepareDown = makeWorld()
    expect(await pluginUpdateCommand(prepareDown.deps, { pluginId: "acme.git-diff/safe" })).toBe(1)

    const applyRejected = makeWorld({
      [APPLY]: [{ body: {}, status: 409 }],
      [PREPARE]: [{ body: plan, status: 201 }]
    })
    expect(
      await pluginUpdateCommand(applyRejected.deps, {
        pluginId: "acme.git-diff/safe",
        yes: true
      })
    ).toBe(1)
    expect(applyRejected.errors).toEqual(["Update failed (status 409)"])

    const applyDown = makeWorld({ [APPLY]: [undefined], [PREPARE]: [{ body: plan, status: 201 }] })
    expect(
      await pluginUpdateCommand(applyDown.deps, { pluginId: "acme.git-diff/safe", yes: true })
    ).toBe(1)
    expect(applyDown.errors[0]).toContain("not running")
  })
})

describe("codevisor plugin recovery controls", () => {
  it("restores the known-good version", async () => {
    const world = makeWorld({
      [RESTORE]: [
        { body: { id: "acme.git-diff/safe", version: "1.0.0" }, status: 200 },
        { body: { id: "acme.git-diff/safe" }, status: 200 }
      ]
    })
    const options = { pluginId: "acme.git-diff/safe" }
    expect(await pluginRestoreCommand(world.deps, options)).toBe(0)
    expect(await pluginRestoreCommand(world.deps, options)).toBe(0)
    expect(world.logs).toEqual(["Restored acme.git-diff/safe 1.0.0", "Restored acme.git-diff/safe"])
    expect(world.requests[0]?.timeoutMs).toBe(600_000)
  })

  it("reports restore refusal and an unreachable server", async () => {
    const refused = makeWorld({ [RESTORE]: [{ body: {}, status: 409 }] })
    expect(await pluginRestoreCommand(refused.deps, { pluginId: "acme.git-diff/safe" })).toBe(1)
    expect(refused.errors).toEqual(["Restore failed (status 409)"])
    const down = makeWorld()
    expect(await pluginRestoreCommand(down.deps, { pluginId: "acme.git-diff/safe" })).toBe(1)
  })

  it("enables and disables without uninstalling", async () => {
    const world = makeWorld({
      [SET_ENABLED]: [
        { body: { enabled: true }, status: 200 },
        { body: { enabled: false }, status: 200 }
      ]
    })
    expect(
      await pluginSetEnabledCommand(world.deps, {
        enabled: true,
        pluginId: "acme.git-diff/safe"
      })
    ).toBe(0)
    expect(
      await pluginSetEnabledCommand(world.deps, {
        enabled: false,
        pluginId: "acme.git-diff/safe"
      })
    ).toBe(0)
    expect(world.logs).toEqual(["Enabled acme.git-diff/safe", "Disabled acme.git-diff/safe"])
    expect(world.requests.map((request) => request.body)).toEqual([
      { enabled: true },
      { enabled: false }
    ])
  })

  it("reports enabled-state refusal and an unreachable server", async () => {
    const refused = makeWorld({ [SET_ENABLED]: [{ body: {}, status: 500 }] })
    expect(
      await pluginSetEnabledCommand(refused.deps, {
        enabled: false,
        pluginId: "acme.git-diff/safe"
      })
    ).toBe(1)
    expect(refused.errors).toEqual(["Changing plugin state failed (status 500)"])
    const down = makeWorld()
    expect(
      await pluginSetEnabledCommand(down.deps, {
        enabled: true,
        pluginId: "acme.git-diff/safe"
      })
    ).toBe(1)
  })
})
