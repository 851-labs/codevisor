import { ChildProcess } from "node:child_process"
import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

import { waitForExit } from "./child-processes.ts"
import { resolveContainerEngine } from "./container-engine.ts"
import {
  containerHostAddress,
  ensureDevContainerImage,
  prepareDevContainers
} from "./dev-containers.ts"
import { developmentLayout } from "./dev-layout.ts"
import { launchDevRemoteServer } from "./dev-remote-server.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

interface FakeEngine {
  readonly directory: string
  readonly calls: () => Promise<Array<Array<string>>>
}

const fakeEngine = async (
  name: "docker" | "container",
  responses: Record<string, string>
): Promise<FakeEngine> => {
  const directory = await mkdtemp(join(tmpdir(), "codevisor-engine-test-"))
  cleanups.push(() => rm(directory, { recursive: true, force: true }))
  const log = join(directory, "calls.jsonl")
  await writeFile(
    join(directory, name),
    `#!${process.execPath}
const fs = require("node:fs")
const args = process.argv.slice(2)
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(args) + "\\n")
const responses = ${JSON.stringify(responses)}
const key = Object.keys(responses).find((prefix) => args.join(" ").startsWith(prefix))
if (key === undefined) process.exit(0)
const reply = responses[key]
if (reply === "FAIL") process.exit(1)
process.stdout.write(reply)
`
  )
  await chmod(join(directory, name), 0o755)
  vi.stubEnv("PATH", `${directory}:${process.env.PATH ?? ""}`)
  return {
    directory,
    calls: async () =>
      (await readFile(log, "utf8").catch(() => ""))
        .split("\n")
        .filter(Boolean)
        .map((line): Array<string> => JSON.parse(line))
  }
}

const fakeRepo = async () => {
  const root = await mkdtemp(join(tmpdir(), "codevisor-container-repo-"))
  cleanups.push(() => rm(root, { recursive: true, force: true }))
  await mkdir(join(root, "packages/sync/dist"), { recursive: true })
  await writeFile(join(root, "package.json"), "{}")
  await writeFile(join(root, "packages/sync/package.json"), '{"name":"sync"}')
  return root
}

describe("resolveContainerEngine", () => {
  it("honors none, docker, and a too-old Apple CLI", async () => {
    expect(await resolveContainerEngine("none")).toBeUndefined()

    await fakeEngine("docker", { version: "27.0.0" })
    expect(await resolveContainerEngine("docker")).toBe("docker")

    const warn = vi.spyOn(console, "warn").mockImplementation(() => {})
    await fakeEngine("container", { "--version": "container CLI version 0.9.0" })
    expect(await resolveContainerEngine("apple")).toBeUndefined()
    expect(warn).toHaveBeenCalledWith(expect.stringContaining("too old"))
  })

  it("prefers a current Apple CLI and falls back to Docker", async () => {
    await fakeEngine("docker", { version: "27.0.0" })
    const apple = await fakeEngine("container", {
      "--version": "container CLI version 1.2.0",
      "system start": ""
    })
    expect(await resolveContainerEngine(undefined, {})).toBe("apple")
    expect(await apple.calls()).toEqual([["--version"], ["system", "start"]])

    await fakeEngine("container", { "--version": "FAIL" })
    expect(
      await resolveContainerEngine(undefined, { CODEVISOR_DEV_CONTAINER_ENGINE: "auto" })
    ).toBe("docker")
  })
})

describe("container images and networking", () => {
  it("pulls the dev image only when it's missing", async () => {
    const present = await fakeEngine("docker", {
      "image inspect": '[{"RepoTags":["node:22-bookworm"]}]'
    })
    await ensureDevContainerImage("docker")
    expect((await present.calls()).map((args) => args[1])).toEqual(["inspect"])

    vi.spyOn(console, "log").mockImplementation(() => {})
    const missing = await fakeEngine("docker", { "image inspect": "FAIL", "image pull": "" })
    await ensureDevContainerImage("docker")
    expect((await missing.calls()).at(-1)).toEqual(["image", "pull", "node:22-bookworm"])
  })

  it("finds the host address containers use to reach the Mac", async () => {
    expect(await containerHostAddress("docker")).toBe("host.docker.internal")

    await fakeEngine("container", {
      "network inspect default": JSON.stringify([{ status: { ipv4Gateway: "192.168.64.1" } }])
    })
    expect(await containerHostAddress("apple")).toBe("192.168.64.1")

    await fakeEngine("container", { "network inspect default": "{}" })
    await expect(containerHostAddress("apple")).rejects.toThrow(/gateway/)
  })
})

describe("prepareDevContainers", () => {
  it("syncs the workspace and provisions it once until it changes", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {})
    const repoRoot = await fakeRepo()
    const containerRoot = join(repoRoot, "tmp/container")
    vi.stubEnv("CODEVISOR_LINUX_BUN_CACHE", join(repoRoot, "bun-cache"))
    const docker = await fakeEngine("docker", {
      "image inspect": "node:22-bookworm ",
      "ps --all": ""
    })

    const context = await prepareDevContainers({
      repoRoot,
      containerRoot,
      engine: "docker",
      worktreeHash: "abc"
    })

    expect(context.hostAddress).toBe("host.docker.internal")
    expect(context.appRoot).toBe(join(containerRoot, "app"))
    expect(await readFile(join(context.appRoot, "packages/sync/package.json"), "utf8")).toBe(
      '{"name":"sync"}'
    )
    const provision = (await docker.calls()).find((args) => args.at(-1) === "--provision-only")
    expect(provision).toContain(`${context.appRoot}:/codevisor`)
    expect(provision).toContain("dev.codevisor.worktree=abc")
  })
})

describe("launchDevRemoteServer", () => {
  it("runs the server in a container with the host's cloud route rewritten", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {})
    const repoRoot = await fakeRepo()
    const remoteRootHost = join(repoRoot, "tmp/remote-cloud")
    const docker = await fakeEngine("docker", { "run --detach": "container-id" })
    const serverRoots = developmentLayout(repoRoot, {}).remoteCloud

    const handle = await launchDevRemoteServer({
      containerContext: {
        engine: "docker",
        worktreeHash: "abcdef123456",
        appRoot: "/app",
        stateRoot: "/state",
        bunCache: "/bun",
        entryScript: "/entry.sh",
        nativesCheck: "/natives.mjs",
        desktopScript: "/desktop.sh",
        desktop: false,
        hostAddress: "host.docker.internal"
      },
      repoRoot,
      remoteRootHost,
      serverRoots,
      port: 47000,
      serverName: "Dev Cloud (cayenne)",
      directPath: undefined,
      environment: {
        CODEVISOR_DEV_CLOUD_URL: "http://127.0.0.1:41000",
        CODEVISOR_DEV_DATA_DIR: serverRoots.data,
        PATH: "/bin"
      }
    })

    const run = (await docker.calls()).find((args) => args[0] === "run")
    expect(run).toContain("codevisor-dev-dev-cloud-cayenne-abcdef1234")
    expect(run).toContain("127.0.0.1:47000:47000")
    expect(run).toContain("CODEVISOR_DEV_CLOUD_URL=http://host.docker.internal:41000")
    expect(run).toContain("CODEVISOR_DEV_DATA_DIR=/codevisor-data/.codevisor/data")
    expect(run?.slice(-4)).toEqual([
      "--name",
      "Dev Cloud (cayenne)",
      "--upgrade-status",
      "/codevisor-data/.codevisor/data/data-upgrade.json"
    ])
    expect(handle.exitCode).toBeNull()
    expect(handle.kill()).toBe(true)
  })

  it("runs the server directly without a container", async () => {
    const repoRoot = await fakeRepo()
    await mkdir(join(repoRoot, "apps/server/dist"), { recursive: true })
    await writeFile(
      join(repoRoot, "apps/server/dist/main.js"),
      "process.exit(process.argv.includes('serve') ? 0 : 9)"
    )
    const serverRoots = developmentLayout(repoRoot, {}).local

    const child = await launchDevRemoteServer({
      containerContext: undefined,
      repoRoot,
      remoteRootHost: repoRoot,
      serverRoots,
      port: 47001,
      serverName: "Local",
      directPath: "/direct",
      environment: { PATH: process.env.PATH }
    })

    if (!(child instanceof ChildProcess)) throw new Error("expected a local server process")
    expect((await waitForExit(child)).code).toBe(0)
  })
})
