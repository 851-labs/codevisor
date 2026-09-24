import { mkdirSync, writeFileSync, rmSync } from "node:fs"
import { join } from "node:path"

import type { AgentRuntimeService, HarnessDefinition } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { afterEach, describe, expect, it, vi } from "vitest"

import {
  cleanupLifecycleTests,
  fakeSpawner,
  fakeTerminal,
  harness,
  installableDefinition,
  makeBinDir,
  makeDb,
  waitForLifecycleSettle
} from "./harness-lifecycle-test-support.js"
import type { HarnessLifecycleManagerConfig } from "./harness-lifecycle-types.js"
import { makeHarnessLifecycleManager } from "./harness-lifecycle.js"

afterEach(cleanupLifecycleTests)
afterEach(() => vi.useRealTimers())

const fixture = async (
  path = "/tools/node/lib/node_modules/fake-cli/bin/cli.js",
  definition: HarnessDefinition = installableDefinition,
  overrides: Partial<HarnessLifecycleManagerConfig> = {}
) => {
  const state = { installed: true }
  const bin = makeBinDir(["npm", "brew", "uv"])
  const spawn = fakeSpawner()
  const terminal = fakeTerminal()
  const agents = {
    catalog: [definition],
    discoverHarnesses: Effect.sync(() => (state.installed ? [harness(definition.id, path)] : [])),
    refreshEnvironment: Effect.void
  } as unknown as AgentRuntimeService
  const lifecycle = makeHarnessLifecycleManager({
    db: await makeDb(),
    agents,
    ...spawn,
    terminal: terminal.terminal,
    resolveEnv: async () => ({ PATH: bin, HOME: "/test-home" }),
    realpath: (value) => value,
    pathExists: () => state.installed,
    fetchImpl: async () => ({
      ok: false,
      status: 404,
      json: async () => ({}),
      text: async () => ""
    }),
    gateEnabled: false,
    operationTimeoutMs: 60_000,
    ...overrides
  })
  return { lifecycle, state, ...spawn, ...terminal }
}

/// Starts an uninstall and returns the command it ran, then fails the fake
/// package manager so no operation outlives the test.
const uninstallCommand = async (world: Awaited<ReturnType<typeof fixture>>, id = "fake-cli") => {
  const settled = waitForLifecycleSettle(world.lifecycle)
  await world.lifecycle.beginUninstall(id)
  world.processes[0]!.emitExit(1)
  await settled
  return world.spawns[0]!.command
}

describe("harness uninstall", () => {
  it("removes only Codex standalone packages and installer-owned launchers", async () => {
    for (const companion of ["owned", "other", "absent"]) {
      const root = "/test-home/.codex/packages/standalone"
      const bin = "/test-home/.local/bin/codex"
      const world = await fixture(
        bin,
        { ...installableDefinition, id: "codex" },
        {
          realpath: (path) =>
            path === bin
              ? `${root}/releases/1/bin/codex`
              : path.endsWith("codex-code-mode-host")
                ? companion === "owned"
                  ? `${root}/releases/1/bin/codex-code-mode-host`
                  : "/other/host"
                : path,
          pathExists: (path) => companion !== "absent" && path.endsWith("codex-code-mode-host")
        }
      )
      const command = await uninstallCommand(world, "codex")
      expect(command).toContain("'/test-home/.codex/packages/standalone'")
      expect(command.includes("'/test-home/.local/bin/codex-code-mode-host'")).toBe(
        companion === "owned"
      )
      expect(command).not.toContain("-- '/test-home/.codex'")
    }
    const root = "/custom/codex/packages/standalone"
    const world = await fixture(
      "/custom/bin/codex",
      { ...installableDefinition, id: "codex" },
      {
        resolveEnv: async () => ({
          PATH: "",
          HOME: "/test-home",
          CODEX_HOME: "/custom/codex",
          CODEX_INSTALL_DIR: "/custom/bin"
        }),
        realpath: (path) => (path === "/custom/bin/codex" ? `${root}/releases/1/codex` : path),
        pathExists: undefined
      }
    )
    expect(await uninstallCommand(world, "codex")).toContain("'/custom/codex/packages/standalone'")
  })

  it("refuses standalone lookalikes and redirected package directories", async () => {
    for (const target of [
      "/elsewhere/codex",
      "/test-home/.codex/packages/standalone/releases/1/bin/codex"
    ]) {
      const world = await fixture(
        "/test-home/.local/bin/codex",
        { ...installableDefinition, id: "codex" },
        {
          realpath: (path) => (path.endsWith("/bin/codex") ? target : "/elsewhere/packages")
        }
      )
      await expect(world.lifecycle.beginUninstall("codex")).rejects.toThrow("original installer")
    }
  })

  it("uses the owning npm prefix, streams progress, verifies removal, and releases dispatch", async () => {
    const world = await fixture("/tools/it's node/lib/node_modules/fake-cli/bin/cli.js")
    await world.lifecycle.beginUninstall("fake-cli")
    await expect(world.lifecycle.beginUninstall("fake-cli")).rejects.toThrow("Another operation")
    expect(world.lifecycle.isGated("fake-cli")).toBe(true)
    expect(world.spawns[0]?.command).toContain("'--prefix' '/tools/it'\\''s node' 'fake-cli'")
    expect(world.spawns[0]?.command).toContain("'--ignore-scripts'")
    await expect(world.lifecycle.beginInstall("fake-cli")).rejects.toThrow("already running")
    await expect(world.lifecycle.beginUpdate("fake-cli")).rejects.toThrow("Uninstall in progress")
    world.processes[0]!.emitOutput("Removed package\n")
    const settled = waitForLifecycleSettle(world.lifecycle)
    world.state.installed = false
    world.processes[0]!.emitExit(0)
    await settled
    expect(world.lifecycle.isGated("fake-cli")).toBe(false)
    expect(world.outputs.join("")).toContain("Removed package")
  })

  it("matches the exact Homebrew cask channel", async () => {
    const world = await fixture("/opt/homebrew/Caskroom/fake-cli@latest/1.0/bin/fake-cli")
    expect(await uninstallCommand(world)).toContain("'uninstall' '--cask' 'fake-cli@latest'")
  })

  it("refuses active chats without starting removal", async () => {
    const world = await fixture()
    world.lifecycle.notifyTurnStarted("fake-cli")
    await expect(world.lifecycle.beginUninstall("fake-cli")).rejects.toThrow("active chats")
    expect(world.spawns).toEqual([])
    expect(world.lifecycle.isGated("fake-cli")).toBe(false)
    world.lifecycle.notifyTurnEnded("fake-cli")
  })

  it.each([
    "/Applications/SomeApp.app/Contents/Resources/fake-cli",
    "/opt/homebrew/Cellar/unrelated/1/bin/fake-cli",
    "/home/person/.local/bin/fake-cli",
    "/project/node_modules/fake-cli/bin/cli.js"
  ])("refuses an unverified installation: %s", async (path) => {
    const world = await fixture(path)
    await expect(world.lifecycle.beginUninstall("fake-cli")).rejects.toThrow()
    expect(world.spawns).toEqual([])
    expect(world.lifecycle.isGated("fake-cli")).toBe(false)
  })

  it("does not report success when the package manager leaves the binary", async () => {
    const world = await fixture()
    await world.lifecycle.beginUninstall("fake-cli")
    const settled = waitForLifecycleSettle(world.lifecycle)
    world.processes[0]!.emitExit(0)
    await settled
    const decorated = await world.lifecycle.decorateHarnesses([
      harness("fake-cli", "/still-installed")
    ])
    expect(decorated[0]?.lifecycle).toMatchObject({
      phase: "failed",
      error: "The installation is still present"
    })
    expect(world.lifecycle.isGated("fake-cli")).toBe(false)
  })

  it("releases dispatch and retains output on a timeout", async () => {
    vi.useFakeTimers()
    const world = await fixture()
    await world.lifecycle.beginUninstall("fake-cli")
    await vi.advanceTimersByTimeAsync(59_999)
    expect(world.lifecycle.isGated("fake-cli")).toBe(true)
    const settled = waitForLifecycleSettle(world.lifecycle)
    await vi.advanceTimersByTimeAsync(1)
    await settled
    expect(world.processes[0]?.killed).toBe(true)
    expect(world.lifecycle.isGated("fake-cli")).toBe(false)
  })
  it("reports absent installations and missing package managers", async () => {
    const absent = await fixture()
    absent.state.installed = false
    await expect(absent.lifecycle.beginUninstall("fake-cli")).rejects.toThrow("Not installed")
    const missing = await fixture(undefined, undefined, { resolveEnv: async () => ({ PATH: "" }) })
    await expect(missing.lifecycle.beginUninstall("fake-cli")).rejects.toThrow(
      "npm is required to uninstall this installation"
    )
    await expect(missing.lifecycle.beginUninstall("unknown")).rejects.toThrow("Unknown harness")
  })

  it("refuses a disappeared binary and a catalog with no installer", async () => {
    const gone = await fixture(undefined, undefined, {
      realpath: () => {
        throw new Error("Gone")
      }
    })
    await expect(gone.lifecycle.beginUninstall("fake-cli")).rejects.toThrow(
      "Installation not found"
    )
    const manual = await fixture("/tools/manual", { ...installableDefinition, installMethods: [] })
    await expect(manual.lifecycle.beginUninstall("fake-cli")).rejects.toThrow("original installer")
  })

  it("uses a verified formula and refuses removal during an install", async () => {
    const world = await fixture("/opt/homebrew/Cellar/fake-cli/1/bin/fake-cli")
    expect(await uninstallCommand(world)).not.toContain("--cask")
    await world.lifecycle.beginInstall("fake-cli")
    await expect(world.lifecycle.beginUninstall("fake-cli")).rejects.toThrow("Another operation")
    const settled = waitForLifecycleSettle(world.lifecycle)
    world.processes[1]!.emitExit(1)
    await settled
  })

  it("targets the owning uv tool directory", async () => {
    const world = await fixture("/alternate/uv/tools/fake-cli/bin/fake-cli", {
      ...installableDefinition,
      installMethods: [{ kind: "uv", packageName: "fake-cli" }]
    })
    await world.lifecycle.beginUninstall("fake-cli")
    expect(world.spawns[0]?.env.UV_TOOL_DIR).toBe("/alternate/uv/tools")
    const settled = waitForLifecycleSettle(world.lifecycle)
    world.state.installed = false
    world.processes[0]!.emitExit(0)
    await settled
  })

  it("only removes the native Claude binary and version directory", async () => {
    const path = "/test-home/.local/bin/claude"
    const root = "/test-home/.local/share/claude"
    const definition = {
      ...installableDefinition,
      id: "claude-code",
      installMethods: [{ kind: "curl" as const, command: "installer" }]
    }
    const world = await fixture(path, definition, {
      realpath: (value) => (value === path ? root + "/versions/1.0" : value)
    })
    expect(await uninstallCommand(world, "claude-code")).toBe(
      "/bin/rm -f -- '/test-home/.local/bin/claude' && /bin/rm -rf -- '/test-home/.local/share/claude'"
    )
    const redirected = await fixture(path, definition, {
      realpath: (value) => (value === path ? root + "/versions/1.0" : "/elsewhere")
    })
    await expect(redirected.lifecycle.beginUninstall("claude-code")).rejects.toThrow(
      "original installer"
    )
  })

  it("verifies removal against the real filesystem and notifies held sessions", async () => {
    const root = makeBinDir([])
    const path = join(root, "lib/node_modules/fake-cli/bin/cli.js")
    mkdirSync(join(root, "lib/node_modules/fake-cli/bin"), { recursive: true })
    writeFileSync(path, "fixture")
    const world = await fixture(path, undefined, {
      realpath: undefined,
      pathExists: undefined
    } as unknown as Partial<HarnessLifecycleManagerConfig>)
    const releases: string[] = []
    world.lifecycle.onGateReleased((id) => releases.push(id))
    await world.lifecycle.beginUninstall("fake-cli")
    rmSync(path)
    world.state.installed = false
    const settled = waitForLifecycleSettle(world.lifecycle)
    world.processes[0]!.emitExit(0)
    await settled
    expect(releases).toEqual(["fake-cli"])
  })

  it("keeps custom commands and unrelated uv environments intact", async () => {
    const { installMethods: _methods, ...manualDefinition } = installableDefinition
    const manual = await fixture("/tools/manual", manualDefinition)
    await expect(manual.lifecycle.beginUninstall("fake-cli")).rejects.toThrow("original installer")
    const uv = await fixture("/somewhere/fake-cli", {
      ...installableDefinition,
      installMethods: [{ kind: "uv", packageName: "fake-cli" }]
    })
    await expect(uv.lifecycle.beginUninstall("fake-cli")).rejects.toThrow("original installer")
  })

  it("releases reservations when process startup throws a non-Error", async () => {
    const world = await fixture(undefined, undefined, {
      spawnShell: () => {
        throw "spawn refused"
      }
    })
    await expect(world.lifecycle.beginUninstall("fake-cli")).rejects.toBe("spawn refused")
    expect(world.lifecycle.isGated("fake-cli")).toBe(false)
  })
})
