import { ChildProcess, spawn, type SpawnOptions } from "node:child_process"
import { access, mkdtemp } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

import { createDevelopmentAppIcon } from "./dev-icons.ts"
import {
  buildIOSDevelopmentApp,
  launchIOSDevelopmentApp,
  terminateIOSDevelopmentApp
} from "./dev-ios-target.ts"
import { developmentLayout } from "./dev-layout.ts"
import { runXcodebuild } from "./xcodebuild.ts"

vi.mock("node:child_process", async (importOriginal) => ({
  ...(await importOriginal<typeof import("node:child_process")>()),
  spawn: vi.fn()
}))

vi.mock("./dev-icons.ts", () => ({ createDevelopmentAppIcon: vi.fn() }))
vi.mock("./xcodebuild.ts", () => ({ runXcodebuild: vi.fn() }))

const spawnMock = vi.mocked(spawn)
const lease = "test-lease"
const simulator = { udid: "test-device", name: "Test iPhone", runtime: "iOS 27.0", lease }
const owner = { pid: 42, startedAt: "first", state: "S" }

const simulatorDependencies = {
  identity: async () => owner,
  read: async () => ({
    format: "codevisor-ios-simulator-v1",
    repoRoot: "/test/repo",
    ready: true,
    owner,
    ...simulator
  }),
  simctl: async () =>
    JSON.stringify({
      devices: { runtime: [{ udid: simulator.udid, name: simulator.name, state: "Booted" }] }
    })
}

const launch = (netCaPem?: string) =>
  launchIOSDevelopmentApp({
    repoRoot: "/test/repo",
    simulatorDependencies,
    target: { simulator, bundleIdentifier: "test.codevisor", appBundle: "/test/Codevisor.app" },
    environment: {},
    worktreeName: "test",
    instanceName: "test-instance",
    developmentIconColor: { hex: "#123456", composer: "#123456" },
    netCaPem
  })

const child = (exitCode: number | null) => Object.assign(new ChildProcess(), { exitCode })

afterEach(() => {
  spawnMock.mockReset()
  vi.restoreAllMocks()
})

describe("launchIOSDevelopmentApp", () => {
  it.each([0, 3])("waits for termination to exit with code %i before launching", async (code) => {
    vi.spyOn(console, "log").mockImplementation(() => {})
    const commands: Array<string | undefined> = []
    const termination = child(null)
    const { promise: terminationStarted, resolve } = Promise.withResolvers<void>()
    spawnMock.mockImplementation((_command: string, args: ReadonlyArray<string>) => {
      commands.push(args[1])
      if (args[1] !== "terminate") return child(0)
      resolve()
      return termination
    })

    const operation = launch()
    await terminationStarted
    await new Promise((settle) => setImmediate(settle))
    expect(commands).toEqual(["install", "terminate"])

    Object.assign(termination, { exitCode: code })
    termination.emit("exit", code, null)
    await operation
    expect(commands).toEqual(["install", "terminate", "launch"])
  })

  it.each([undefined, "-----BEGIN CERTIFICATE-----\ntest\n"])(
    "passes the dev relay CA %s only when set",
    async (netCaPem) => {
      vi.spyOn(console, "log").mockImplementation(() => {})
      const launches: Array<NodeJS.ProcessEnv | undefined> = []
      spawnMock.mockImplementation(
        (_command: string, args: ReadonlyArray<string>, options?: SpawnOptions) => {
          if (args[1] === "launch") launches.push(options?.env)
          return child(0)
        }
      )

      await launch(netCaPem)

      expect(launches).toHaveLength(1)
      expect(launches[0]?.SIMCTL_CHILD_CODEVISOR_NET_CA_PEM).toBe(netCaPem)
    }
  )

  it("refuses to launch when the simulator changed during the build", async () => {
    spawnMock.mockImplementation(() => child(0))
    await expect(
      launchIOSDevelopmentApp({
        repoRoot: "/test/repo",
        simulatorDependencies,
        target: {
          simulator: { ...simulator, lease: "old" },
          bundleIdentifier: "test.codevisor",
          appBundle: "/test/Codevisor.app"
        },
        environment: {},
        worktreeName: "test",
        instanceName: "test-instance",
        developmentIconColor: { hex: "#123456", composer: "#123456" }
      })
    ).rejects.toThrow(/simulator changed/)
    expect(spawnMock).not.toHaveBeenCalled()
  })
})

describe("buildIOSDevelopmentApp", () => {
  it("builds the worktree simulator's app and removes the generated icon even when the build fails", async () => {
    vi.spyOn(console, "log").mockImplementation(() => {})
    const icon = await mkdtemp(join(tmpdir(), "codevisor-ios-icon-"))
    vi.mocked(createDevelopmentAppIcon).mockResolvedValue(icon)
    vi.mocked(runXcodebuild).mockRejectedValueOnce(new Error("xcodebuild failed (code 65)"))
    const layout = developmentLayout("/test/repo", {})
    const build = () =>
      buildIOSDevelopmentApp({
        repoRoot: "/test/repo",
        layout,
        appDisplayName: "Codevisor test",
        bundleIdentifier: "test.codevisor",
        urlScheme: "codevisor-test",
        developmentIconColor: { hex: "#123456", composer: "#123456" },
        simulatorDependencies,
        environment: {}
      })

    await expect(build()).rejects.toThrow(/code 65/)
    await expect(access(icon)).rejects.toThrow()

    const target = await build()
    expect(target.appBundle).toBe(
      join(layout.build.ios.derivedData, "Build/Products/Debug-iphonesimulator/Codevisor.app")
    )
    expect(vi.mocked(runXcodebuild).mock.calls[1]?.[2]).toContain(
      `platform=iOS Simulator,id=${simulator.udid}`
    )

    spawnMock.mockImplementation(() => child(0))
    await terminateIOSDevelopmentApp(target)
    expect(spawnMock).toHaveBeenCalledWith(
      "xcrun",
      ["simctl", "terminate", simulator.udid, "test.codevisor"],
      { stdio: "ignore" }
    )
  })
})
