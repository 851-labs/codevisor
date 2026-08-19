import { execFileSync } from "node:child_process"
import { existsSync, mkdirSync, symlinkSync, writeFileSync } from "node:fs"
import { cp, readFile } from "node:fs/promises"
import { join } from "node:path"
import { describe, expect, it } from "vitest"
import { makePluginInstaller, type PluginInstallerDeps } from "./plugin-install.js"
import { MANAGED_PLUGIN_MARKER, scanPlugins } from "./plugin-store.js"
import type { PluginProcessHandle, PluginSpawnOptions } from "./plugin-supervisor.js"
import { exampleManifest, makeDir, writePlugin } from "./test-support.js"

/// Copies whatever the "clone URL" points at — local fixture directories in
/// these tests — so nothing touches the network.
const copyClone = async (
  url: string,
  _ref: string | undefined,
  destination: string
): Promise<void> => {
  await cp(url, destination, { recursive: true })
}

const failingClone = async (): Promise<void> => {
  throw new Error("repository not found")
}

interface InstallSpawn {
  readonly calls: Array<{ command: string; cwd: string; env: NodeJS.ProcessEnv }>
  readonly spawnShell: (command: string, options: PluginSpawnOptions) => PluginProcessHandle
}

const makeInstallSpawn = (exitCode: number | null, output = ""): InstallSpawn => {
  const calls: InstallSpawn["calls"] = []
  return {
    calls,
    spawnShell: (command, options) => {
      calls.push({ command, cwd: options.cwd, env: options.env })
      const exitListeners: Array<(message: string, code?: number | null) => void> = []
      const outputListeners: Array<(data: string) => void> = []
      setImmediate(() => {
        if (output !== "") {
          for (const listener of outputListeners) {
            listener(output)
          }
        }
        for (const listener of exitListeners) {
          listener(exitCode === 0 ? "exited with code 0" : "install blew up", exitCode)
        }
      })
      return {
        kill: () => undefined,
        onExit: (listener) => exitListeners.push(listener),
        pid: 7,
        // Spawners without an output stream are legal (PluginProcessHandle
        // marks onOutput optional); provide one only when there is output.
        ...(output === ""
          ? {}
          : { onOutput: (listener: (data: string) => void) => outputListeners.push(listener) })
      }
    }
  }
}

const makeFixture = (manifest: Record<string, unknown>): string => {
  const fixture = makeDir("codevisor-plugin-fixture-")
  writeFileSync(join(fixture, "codevisor-plugin.json"), JSON.stringify(manifest))
  writeFileSync(join(fixture, "server.js"), "// plugin server")
  return fixture
}

const makeInstaller = (
  overrides: Partial<PluginInstallerDeps> = {}
): { installer: ReturnType<typeof makePluginInstaller>; root: string; stopped: Array<string> } => {
  const root = makeDir("codevisor-plugins-root-")
  const stopped: Array<string> = []
  const installer = makePluginInstaller({
    clone: copyClone,
    pluginsRoot: root,
    resolveEnv: async () => ({ PATH: "/usr/bin" }),
    stop: (pluginId) => stopped.push(pluginId),
    ...overrides
  })
  return { installer, root, stopped }
}

describe("discoverRemote", () => {
  it("stages the source and reports the verbatim install/run commands", async () => {
    const fixture = makeFixture({
      ...exampleManifest,
      install: { command: "bun install" }
    })
    const { installer } = makeInstaller()
    const discovered = await installer.discoverRemote({ source: fixture })
    expect(discovered).toEqual({
      alreadyInstalled: false,
      description: "Example plugin",
      id: "owner.example",
      installCommand: "bun install",
      name: "Example",
      panes: [{ path: "/panes/main/", title: "Main", type: "main" }],
      runCommand: "run-me",
      version: "0.1.0"
    })
  })

  it("omits absent optional fields and flags already-installed ids", async () => {
    const fixture = makeFixture({ ...exampleManifest, description: undefined })
    const { installer, root } = makeInstaller()
    const first = await installer.discoverRemote({ source: fixture })
    expect(first.description).toBeUndefined()
    expect(first.installCommand).toBeUndefined()
    writePlugin(root, "already", exampleManifest)
    const second = await installer.discoverRemote({ source: fixture })
    expect(second.alreadyInstalled).toBe(true)
  })

  it("surfaces clone failures with the source coordinates", async () => {
    const { installer } = makeInstaller({ clone: failingClone })
    await expect(installer.discoverRemote({ source: "acme/tools" })).rejects.toThrow(
      /Couldn't fetch https:\/\/github.com\/acme\/tools.git: repository not found/
    )
    await expect(installer.discoverRemote({ source: "acme/tools#v2" })).rejects.toThrow(
      /\(v2\): repository not found/
    )
    // Non-Error throwables stringify instead of vanishing.
    const stringThrow = makeInstaller({
      clone: () => Promise.reject("wire cut")
    })
    await expect(stringThrow.installer.discoverRemote({ source: "acme/tools" })).rejects.toThrow(
      /wire cut/
    )
  })

  it("rejects sources without a manifest and unsafe subpaths", async () => {
    const empty = makeDir("codevisor-plugin-empty-")
    const { installer } = makeInstaller()
    await expect(installer.discoverRemote({ source: empty })).rejects.toThrow(
      /No codevisor-plugin.json found/
    )
    // The traversal check fires after staging, before any manifest read.
    const staged = makeInstaller({
      clone: (_url, ref, destination) => copyClone(empty, ref, destination)
    })
    await expect(
      staged.installer.discoverRemote({ source: "acme/tools/../escape" })
    ).rejects.toThrow(/Invalid source path/)
  })

  it("finds the manifest under a repo subpath", async () => {
    const repo = makeDir("codevisor-plugin-monorepo-")
    mkdirSync(join(repo, "plugins", "diff"), { recursive: true })
    writeFileSync(
      join(repo, "plugins", "diff", "codevisor-plugin.json"),
      JSON.stringify({ ...exampleManifest, id: "acme.diff" })
    )
    // The fake clone copies the fixture regardless of URL; the subpath comes
    // from the parsed source.
    const { installer } = makeInstaller({
      clone: (_url, ref, destination) => copyClone(repo, ref, destination)
    })
    const discovered = await installer.discoverRemote({ source: "acme/tools/plugins/diff" })
    expect(discovered.id).toBe("acme.diff")
  })

  it("enforces the owner namespace for GitHub sources but not local paths", async () => {
    const impersonator = makeFixture({ ...exampleManifest, id: "somebodyelse.example" })
    const { installer } = makeInstaller({
      clone: (_url, ref, destination) => copyClone(impersonator, ref, destination)
    })
    await expect(installer.discoverRemote({ source: "Acme/tools" })).rejects.toThrow(
      /must use ids starting with "acme\."/
    )
    // The same manifest from a local path is a dev install: exempt.
    const local = makeInstaller()
    const discovered = await local.installer.discoverRemote({ source: impersonator })
    expect(discovered.id).toBe("somebodyelse.example")
    // Ownerless remotes (raw git URLs) have nothing to validate against.
    const ownerless = makeInstaller({
      clone: (_url, ref, destination) => copyClone(impersonator, ref, destination)
    })
    const viaGitUrl = await ownerless.installer.discoverRemote({
      source: "git@example.com:acme/tools.git"
    })
    expect(viaGitUrl.id).toBe("somebodyelse.example")
  })
})

describe("importRemote", () => {
  it("copies the plugin into the root with the managed marker", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root } = makeInstaller()
    const manifest = await installer.importRemote({ source: fixture })
    expect(manifest.id).toBe("owner.example")
    const destination = join(root, "owner.example")
    expect(existsSync(join(destination, "codevisor-plugin.json"))).toBe(true)
    expect(existsSync(join(destination, "server.js"))).toBe(true)
    expect(existsSync(join(destination, MANAGED_PLUGIN_MARKER))).toBe(true)
    expect(scanPlugins(root).plugins[0]?.source).toBe("managed")
  })

  it("runs the manifest install command in the plugin dir, streaming output", async () => {
    const fixture = makeFixture({ ...exampleManifest, install: { command: "bun install" } })
    const spawn = makeInstallSpawn(0, "installed 3 packages\n")
    const frames: Array<string> = []
    const sessions: Array<string> = []
    let terminalProcess:
      | { kill: () => void; resize: (c: number, r: number) => void; write: (d: string) => void }
      | undefined
    const { installer, root } = makeInstaller({
      registerExternalTerminal: (config, process) => {
        sessions.push(config.sessionId)
        terminalProcess = process
        return {
          exit: (code) => frames.push(`[exit ${code}]`),
          output: (data) => frames.push(data),
          terminalId: "terminal-1"
        }
      },
      spawnShell: spawn.spawnShell
    })
    await installer.importRemote({ source: fixture })
    // The terminal's process handle is inert plumbing: writes and resizes
    // no-op, kill forwards to the child.
    terminalProcess?.write("ignored")
    terminalProcess?.resize(80, 24)
    terminalProcess?.kill()
    expect(sessions).toEqual(["plugin-install:owner.example"])
    expect(spawn.calls).toHaveLength(1)
    expect(spawn.calls[0]?.command).toBe("bun install")
    expect(spawn.calls[0]?.cwd).toBe(join(root, "owner.example"))
    expect(spawn.calls[0]?.env["CODEVISOR_PLUGIN_ID"]).toBe("owner.example")
    expect(spawn.calls[0]?.env["PATH"]).toBe("/usr/bin")
    expect(frames.join("")).toContain("$ bun install")
    expect(frames.join("")).toContain("installed 3 packages")
    expect(frames.join("")).toContain("[exit 0]")
  })

  it("removes the copied directory when the install command fails", async () => {
    const fixture = makeFixture({ ...exampleManifest, install: { command: "bun install" } })
    const { installer, root } = makeInstaller({ spawnShell: makeInstallSpawn(1).spawnShell })
    await expect(installer.importRemote({ source: fixture })).rejects.toThrow(
      /install command failed: install blew up/
    )
    expect(existsSync(join(root, "owner.example"))).toBe(false)
    // Launch failures (null exit code) fail the same way, and the terminal
    // closes without a numeric status.
    const exits: Array<number | undefined> = []
    const spawnless = makeInstaller({
      registerExternalTerminal: () => ({
        exit: (code) => {
          exits.push(code)
        },
        output: () => undefined,
        terminalId: "terminal-2"
      }),
      spawnShell: makeInstallSpawn(null).spawnShell
    })
    await expect(spawnless.installer.importRemote({ source: fixture })).rejects.toThrow(
      /install command failed/
    )
    expect(exits).toEqual([undefined])
  })

  it("updates an existing managed install in place, stopping it first", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root, stopped } = makeInstaller()
    await installer.importRemote({ source: fixture })
    writeFileSync(join(root, "owner.example", "stale.txt"), "old")
    writeFileSync(
      join(fixture, "codevisor-plugin.json"),
      JSON.stringify({ ...exampleManifest, version: "0.2.0" })
    )
    const updated = await installer.importRemote({ source: fixture })
    expect(updated.version).toBe("0.2.0")
    expect(stopped).toEqual(["owner.example"])
    expect(existsSync(join(root, "owner.example", "stale.txt"))).toBe(false)
    const manifest = await readFile(join(root, "owner.example", "codevisor-plugin.json"), "utf8")
    expect(manifest).toContain("0.2.0")
  })

  it("refuses to overwrite directories Codevisor did not create", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root } = makeInstaller()
    // A user-made directory at the destination (no managed marker).
    writePlugin(root, "owner.example", exampleManifest)
    await expect(installer.importRemote({ source: fixture })).rejects.toThrow(
      /was not installed by Codevisor/
    )
    expect(existsSync(join(root, "owner.example", "codevisor-plugin.json"))).toBe(true)
  })

  it("conflicts when another directory already provides the plugin id", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root } = makeInstaller()
    writePlugin(root, "dev-checkout", exampleManifest)
    await expect(installer.importRemote({ source: fixture })).rejects.toThrow(
      /already provided by dev-checkout \(linked\)/
    )
  })

  it("installs from a real local git repository, excluding .git", async () => {
    const repo = makeDir("codevisor-plugin-git-")
    writeFileSync(
      join(repo, "codevisor-plugin.json"),
      JSON.stringify({ ...exampleManifest, id: "local.dev", install: { command: "printf ok" } })
    )
    const git = (...args: Array<string>): void => {
      execFileSync("git", ["-C", repo, ...args], { stdio: "ignore" })
    }
    git("init", "--quiet", "--initial-branch", "main")
    git("-c", "user.email=t@example.com", "-c", "user.name=t", "add", ".")
    git("-c", "user.email=t@example.com", "-c", "user.name=t", "commit", "--quiet", "-m", "x")
    const root = makeDir("codevisor-plugins-root-")
    // No injected clone/spawn/env: the default git clone and login-shell
    // install runner do the work end to end.
    const installer = makePluginInstaller({ pluginsRoot: root, stop: () => undefined })
    const manifest = await installer.importRemote({ source: repo })
    expect(manifest.id).toBe("local.dev")
    expect(existsSync(join(root, "local.dev", "codevisor-plugin.json"))).toBe(true)
    expect(existsSync(join(root, "local.dev", ".git"))).toBe(false)
    expect(existsSync(join(root, "local.dev", MANAGED_PLUGIN_MARKER))).toBe(true)
  })
})

describe("link", () => {
  it("symlinks a valid local plugin directory into the root", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root } = makeInstaller()
    const manifest = await installer.link({ path: fixture })
    expect(manifest.id).toBe("owner.example")
    const scan = scanPlugins(root)
    expect(scan.plugins[0]?.id).toBe("owner.example")
    expect(scan.plugins[0]?.source).toBe("linked")
  })

  it("validates the path before touching the plugins root", async () => {
    const { installer } = makeInstaller()
    await expect(installer.link({ path: "relative/path" })).rejects.toThrow(/must be absolute/)
    await expect(installer.link({ path: "/nonexistent/plugin" })).rejects.toThrow(/Not a directory/)
    const file = join(makeDir("codevisor-plugin-file-"), "file.txt")
    writeFileSync(file, "not a dir")
    await expect(installer.link({ path: file })).rejects.toThrow(/Not a directory/)
    const empty = makeDir("codevisor-plugin-empty-")
    await expect(installer.link({ path: empty })).rejects.toThrow(/No codevisor-plugin.json/)
  })

  it("conflicts on duplicate ids and occupied destinations", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root } = makeInstaller()
    await installer.link({ path: fixture })
    await expect(installer.link({ path: fixture })).rejects.toThrow(/already installed/)
    // A destination entry the scan does not recognize (no manifest) still
    // blocks the link.
    const other = makeFixture({ ...exampleManifest, id: "owner.other" })
    mkdirSync(join(root, "owner.other"))
    await expect(installer.link({ path: other })).rejects.toThrow(/already exists/)
  })
})

describe("remove", () => {
  it("deletes managed installs after stopping them", async () => {
    const fixture = makeFixture(exampleManifest)
    const { installer, root, stopped } = makeInstaller()
    await installer.importRemote({ source: fixture })
    await installer.remove("owner.example")
    expect(stopped).toEqual(["owner.example"])
    expect(existsSync(join(root, "owner.example"))).toBe(false)
  })

  it("404s unknown plugins", async () => {
    const { installer } = makeInstaller()
    await expect(installer.remove("owner.ghost")).rejects.toThrow(/not installed/)
  })

  it("never deletes linked plugins — even links whose target carries a marker", async () => {
    const fixture = makeFixture(exampleManifest)
    writeFileSync(join(fixture, MANAGED_PLUGIN_MARKER), "sneaky")
    const { installer, root } = makeInstaller()
    symlinkSync(fixture, join(root, "owner.example"))
    await expect(installer.remove("owner.example")).rejects.toThrow(/linked, not managed/)
    expect(existsSync(join(fixture, "codevisor-plugin.json"))).toBe(true)
    expect(existsSync(join(root, "owner.example"))).toBe(true)
  })

  it("refuses real directories without the managed marker", async () => {
    const { installer, root } = makeInstaller()
    writePlugin(root, "owner.example", exampleManifest)
    await expect(installer.remove("owner.example")).rejects.toThrow(/linked, not managed/)
    expect(existsSync(join(root, "owner.example"))).toBe(true)
  })
})
