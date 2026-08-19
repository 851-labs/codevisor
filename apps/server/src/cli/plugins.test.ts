import { describe, expect, it } from "vitest"
import {
  pluginInstallCommand,
  pluginLinkCommand,
  pluginListCommand,
  pluginRemoveCommand,
  type PluginsCliDeps
} from "./plugins.js"

interface FakeWorld {
  readonly deps: PluginsCliDeps
  readonly logs: string[]
  readonly errors: string[]
  readonly requests: Array<{ key: string; body?: unknown }>
  readonly confirmMessages: string[]
}

interface FakeOptions {
  /// Keyed by "METHOD url" → responses returned in order (last repeats).
  readonly http?: Record<string, ReadonlyArray<{ status: number; body?: unknown } | undefined>>
  readonly confirmAnswer?: boolean
}

const makeWorld = (options: FakeOptions = {}): FakeWorld => {
  const logs: string[] = []
  const errors: string[] = []
  const requests: Array<{ key: string; body?: unknown }> = []
  const confirmMessages: string[] = []
  const httpCounts = new Map<string, number>()
  const deps: PluginsCliDeps = {
    confirm: (message) => {
      confirmMessages.push(message)
      return Promise.resolve(options.confirmAnswer ?? true)
    },
    dataDir: "/tmp/data",
    env: { CODEVISOR_PORT: "49361" },
    error: (line) => errors.push(line),
    exec: () => Promise.resolve({ code: 1, stderr: "", stdout: "" }),
    execInteractive: () => Promise.resolve(0),
    fetchJson: (url, init) => {
      const key = `${init?.method ?? "GET"} ${url}`
      requests.push({ key, ...(init?.body === undefined ? {} : { body: init.body }) })
      const responses = options.http?.[key] ?? [undefined]
      const index = httpCounts.get(key) ?? 0
      httpCounts.set(key, index + 1)
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
    spawnDetachedServer: () => Promise.resolve(4242),
    writeTextFile: () => undefined
  }
  return { confirmMessages, deps, errors, logs, requests }
}

const DISCOVER = "POST http://127.0.0.1:49361/v1/plugins/discover-remote"
const IMPORT = "POST http://127.0.0.1:49361/v1/plugins/import-remote"
const LINK = "POST http://127.0.0.1:49361/v1/plugins/link"
const LIST = "GET http://127.0.0.1:49361/v1/plugins"

const discovery = {
  alreadyInstalled: false,
  description: "Live git diff viewer",
  id: "acme.git-diff",
  installCommand: "bun install",
  name: "Git Diff",
  panes: [{ title: "Git Diff", type: "diff" }],
  runCommand: "bun run start",
  tools: [{ description: "Summarize the working tree diff", name: "diff_summary" }],
  version: "0.1.0"
}

describe("codevisor plugin install", () => {
  it("shows the discovered manifest and verbatim commands, then installs on consent", async () => {
    const world = makeWorld({
      http: {
        [DISCOVER]: [{ body: discovery, status: 200 }],
        [IMPORT]: [
          { body: { id: "acme.git-diff", source: "managed", version: "0.1.0" }, status: 201 }
        ]
      }
    })
    const code = await pluginInstallCommand(world.deps, { source: "acme/git-diff" })
    expect(code).toBe(0)
    expect(world.requests).toContainEqual({ body: { source: "acme/git-diff" }, key: DISCOVER })
    expect(world.requests).toContainEqual({ body: { source: "acme/git-diff" }, key: IMPORT })
    const output = world.logs.join("\n")
    expect(output).toContain("Git Diff 0.1.0")
    expect(output).toContain("id:      acme.git-diff")
    expect(output).toContain("about:   Live git diff viewer")
    expect(output).toContain("pane:    Git Diff (diff)")
    // Declared agent tools appear in the consent output next to the commands.
    expect(output).toContain("tool:    diff_summary — Summarize the working tree diff")
    expect(output).toContain("Installing will run these commands on your machine:")
    expect(output).toContain("install: bun install")
    expect(output).toContain("run:     bun run start")
    expect(output).toContain("Installed acme.git-diff 0.1.0")
    expect(world.confirmMessages).toEqual(["Install Git Diff?"])
  })

  it("aborts without installing when consent is declined", async () => {
    // A nameless manifest falls back to the id in the prompt.
    const world = makeWorld({
      confirmAnswer: false,
      http: {
        [DISCOVER]: [{ body: { id: "acme.git-diff", runCommand: "bun run start" }, status: 200 }]
      }
    })
    expect(await pluginInstallCommand(world.deps, { source: "acme/git-diff" })).toBe(1)
    expect(world.confirmMessages).toEqual(["Install acme.git-diff?"])
    expect(world.logs.join("\n")).toContain("Cancelled.")
    expect(world.requests.some((request) => request.key === IMPORT)).toBe(false)
  })

  it("skips the prompt with --yes and notes updates of existing installs", async () => {
    const world = makeWorld({
      http: {
        [DISCOVER]: [
          {
            body: {
              alreadyInstalled: true,
              id: "acme.git-diff",
              runCommand: "bun run start"
            },
            status: 200
          }
        ],
        [IMPORT]: [{ body: { id: "acme.git-diff" }, status: 201 }]
      }
    })
    expect(await pluginInstallCommand(world.deps, { source: "acme/git-diff", yes: true })).toBe(0)
    expect(world.confirmMessages).toEqual([])
    const output = world.logs.join("\n")
    expect(output).toContain("already installed; this will update it")
    expect(output).toContain("Installed acme.git-diff")
  })

  it("reports discovery failures, install failures, and an unreachable server", async () => {
    const down = makeWorld()
    expect(await pluginInstallCommand(down.deps, { source: "acme/git-diff" })).toBe(1)
    expect(down.errors.join("\n")).toContain("not running on port 49361")

    const badSource = makeWorld({
      http: { [DISCOVER]: [{ body: { error: "No codevisor-plugin.json found" }, status: 400 }] }
    })
    expect(await pluginInstallCommand(badSource.deps, { source: "acme/empty" })).toBe(1)
    expect(badSource.errors.join("\n")).toContain("No codevisor-plugin.json found")

    const failedImport = makeWorld({
      http: {
        [DISCOVER]: [{ body: discovery, status: 200 }],
        [IMPORT]: [{ body: {}, status: 409 }]
      }
    })
    expect(await pluginInstallCommand(failedImport.deps, { source: "a/b", yes: true })).toBe(1)
    expect(failedImport.errors.join("\n")).toContain("Install failed (status 409)")

    const dropped = makeWorld({
      http: { [DISCOVER]: [{ body: discovery, status: 200 }], [IMPORT]: [undefined] }
    })
    expect(await pluginInstallCommand(dropped.deps, { source: "a/b", yes: true })).toBe(1)
  })
})

describe("codevisor plugin link", () => {
  it("links an absolute path and resolves relative ones", async () => {
    const world = makeWorld({
      http: {
        [LINK]: [
          { body: { id: "local.dev", version: "0.0.1" }, status: 201 },
          // Older servers may omit the version; the output stays tidy.
          { body: { id: "local.dev" }, status: 201 }
        ]
      }
    })
    expect(await pluginLinkCommand(world.deps, { path: "/abs/plugin" })).toBe(0)
    expect(world.requests[0]?.body).toEqual({ path: "/abs/plugin" })
    expect(world.logs.join("\n")).toContain("Linked local.dev 0.0.1")

    expect(await pluginLinkCommand(world.deps, { path: "relative/plugin" })).toBe(0)
    const second = world.requests[1]?.body as { path: string }
    expect(second.path.startsWith("/")).toBe(true)
    expect(second.path.endsWith("/relative/plugin")).toBe(true)
  })

  it("surfaces link failures and an unreachable server", async () => {
    const invalid = makeWorld({
      http: { [LINK]: [{ body: { error: "No codevisor-plugin.json found" }, status: 400 }] }
    })
    expect(await pluginLinkCommand(invalid.deps, { path: "/abs/empty" })).toBe(1)
    expect(invalid.errors.join("\n")).toContain("No codevisor-plugin.json found")
    const down = makeWorld()
    expect(await pluginLinkCommand(down.deps, { path: "/abs/plugin" })).toBe(1)
  })
})

describe("codevisor plugin list", () => {
  it("prints installed plugins with source and state", async () => {
    const world = makeWorld({
      http: {
        [LIST]: [
          {
            body: {
              plugins: [
                {
                  id: "acme.git-diff",
                  name: "Git Diff",
                  source: "managed",
                  state: "running",
                  version: "0.1.0"
                },
                { id: "local.dev" }
              ]
            },
            status: 200
          }
        ]
      }
    })
    expect(await pluginListCommand(world.deps)).toBe(0)
    expect(world.logs[0]).toContain("acme.git-diff")
    expect(world.logs[0]).toContain("managed")
    expect(world.logs[0]).toContain("running")
    expect(world.logs[1]).toContain("local.dev")
  })

  it("handles empty lists, feature-less servers, and an unreachable server", async () => {
    const empty = makeWorld({ http: { [LIST]: [{ body: { plugins: [] }, status: 200 }] } })
    expect(await pluginListCommand(empty.deps)).toBe(0)
    expect(empty.logs.join("\n")).toContain("No plugins installed")

    const bodyless = makeWorld({ http: { [LIST]: [{ body: {}, status: 200 }] } })
    expect(await pluginListCommand(bodyless.deps)).toBe(0)

    const unavailable = makeWorld({
      http: { [LIST]: [{ body: { error: "Plugins are unavailable" }, status: 501 }] }
    })
    expect(await pluginListCommand(unavailable.deps)).toBe(1)
    expect(unavailable.errors.join("\n")).toContain("Plugins are unavailable")

    const blank = makeWorld({ http: { [LIST]: [{ body: {}, status: 500 }] } })
    expect(await pluginListCommand(blank.deps)).toBe(1)
    expect(blank.errors.join("\n")).toContain("Listing plugins failed (status 500)")

    const down = makeWorld()
    expect(await pluginListCommand(down.deps)).toBe(1)
  })
})

describe("codevisor plugin remove", () => {
  it("removes managed plugins by id", async () => {
    const world = makeWorld({
      http: {
        "DELETE http://127.0.0.1:49361/v1/plugins/acme.git-diff": [
          { body: { plugins: [] }, status: 200 }
        ]
      }
    })
    expect(await pluginRemoveCommand(world.deps, { pluginId: "acme.git-diff" })).toBe(0)
    expect(world.logs.join("\n")).toContain("Removed acme.git-diff")
  })

  it("surfaces refusals (linked plugins) and an unreachable server", async () => {
    const linked = makeWorld({
      http: {
        "DELETE http://127.0.0.1:49361/v1/plugins/local.dev": [
          { body: { error: "linked, not managed" }, status: 400 }
        ]
      }
    })
    expect(await pluginRemoveCommand(linked.deps, { pluginId: "local.dev" })).toBe(1)
    expect(linked.errors.join("\n")).toContain("linked, not managed")
    const down = makeWorld()
    expect(await pluginRemoveCommand(down.deps, { pluginId: "acme.git-diff" })).toBe(1)
  })
})
