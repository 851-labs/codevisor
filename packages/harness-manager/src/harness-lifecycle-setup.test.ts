import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { Effect } from "effect"
import { afterEach, describe, expect, it } from "vitest"

import {
  cleanupLifecycleTests,
  fakeSpawner,
  fakeTerminal,
  installableDefinition,
  makeBinDir,
  makeDb,
  waitForLifecycleSettle
} from "./harness-lifecycle-test-support.js"
import type { PendingHarnessSetup } from "./harness-lifecycle-types.js"
import { makeHarnessLifecycleManager } from "./harness-lifecycle.js"

afterEach(cleanupLifecycleTests)

/// A harness setup the test finishes: `checked` resolves once the lifecycle
/// asks for it, `finish` settles it.
const controlledSetup = () => {
  const checked = Promise.withResolvers<NodeJS.ProcessEnv>()
  const finished = Promise.withResolvers<void>()
  const pending: PendingHarnessSetup = { finish: () => finished.promise }
  return {
    checked: checked.promise,
    fail: (message: string) => finished.reject(new Error(message)),
    finish: () => finished.resolve(),
    setup: async (env: NodeJS.ProcessEnv) => {
      checked.resolve(env)
      return pending
    }
  }
}

const makeLifecycle = async (
  harnessSetup: NonNullable<Parameters<typeof makeHarnessLifecycleManager>[0]["harnessSetup"]>
) => {
  const bin = makeBinDir(["brew"])
  const agents = {
    catalog: [installableDefinition],
    discoverHarnesses: Effect.succeed([]),
    refreshEnvironment: Effect.void
  } as unknown as AgentRuntimeService
  const spawner = fakeSpawner()
  const lifecycle = makeHarnessLifecycleManager({
    agents,
    db: await makeDb(),
    fetchImpl: async () => ({
      json: async () => ({}),
      ok: false,
      status: 404,
      text: async () => ""
    }),
    harnessSetup,
    resolveEnv: async () => ({ PATH: bin }),
    spawnShell: spawner.spawnShell,
    terminal: fakeTerminal().terminal
  })
  const phases: Array<string | undefined> = []
  lifecycle.subscribe((event) => {
    phases.push((event.payload as { lifecycle?: { phase?: string } }).lifecycle?.phase)
  })
  const released: Array<string> = []
  lifecycle.onGateReleased((harnessId) => released.push(harnessId))
  return { bin, lifecycle, phases, released, spawner }
}

describe("harness setup after an install or update", () => {
  it("stays installing, with prompts held, until the harness's setup is done", async () => {
    const setup = controlledSetup()
    const { bin, lifecycle, phases, released, spawner } = await makeLifecycle({
      "fake-cli": setup.setup
    })
    await lifecycle.beginInstall("fake-cli")
    spawner.processes[0]!.emitExit(0)
    expect(await setup.checked).toEqual({ PATH: bin })
    expect(lifecycle.isGated("fake-cli")).toBe(true)
    expect(phases).toEqual(["installing"])

    const settled = waitForLifecycleSettle(lifecycle)
    setup.finish()
    await settled
    expect(phases).toEqual(["installing", "idle"])
    expect(lifecycle.isGated("fake-cli")).toBe(false)
    expect(released).toEqual(["fake-cli"])
  })

  it("fails the install with the harness's reason when its setup fails", async () => {
    const setup = controlledSetup()
    const { lifecycle, released, spawner } = await makeLifecycle({ "fake-cli": setup.setup })
    await lifecycle.beginInstall("fake-cli")
    spawner.processes[0]!.emitExit(0)
    await setup.checked
    const settled = waitForLifecycleSettle(lifecycle)
    setup.fail("OpenCode couldn't migrate its sessions: disk full")
    await settled
    const [decorated] = await lifecycle.decorateHarnesses([
      {
        enabled: true,
        id: "fake-cli",
        launchKind: "executable",
        name: "Fake CLI",
        readiness: { path: "/bin/fake-cli", state: "ready" },
        source: "registry",
        symbolName: "terminal"
      }
    ])
    expect(decorated?.lifecycle).toMatchObject({
      error: "OpenCode couldn't migrate its sessions: disk full",
      phase: "failed"
    })
    expect(lifecycle.isGated("fake-cli")).toBe(false)
    expect(released).toEqual(["fake-cli"])
  })
})

describe("harness setup at startup", () => {
  it("shows a needed setup as updating, holding prompts, then restores the harness", async () => {
    const setup = controlledSetup()
    const { lifecycle, phases, released } = await makeLifecycle({ "fake-cli": setup.setup })
    const updating = new Promise<void>((shown) => lifecycle.subscribe(() => shown()))
    const finishing = lifecycle.finishPendingSetup()
    await updating
    expect(lifecycle.isGated("fake-cli")).toBe(true)
    expect(phases).toEqual(["updating"])
    setup.finish()
    await finishing
    expect(phases).toEqual(["updating", "idle"])
    expect(lifecycle.isGated("fake-cli")).toBe(false)
    expect(released).toEqual(["fake-cli"])
  })

  it("reports a setup that fails, but not a check that couldn't run", async () => {
    const failing = controlledSetup()
    const { lifecycle, phases } = await makeLifecycle({
      "fake-cli": failing.setup,
      unchecked: async () => {
        throw new Error("OpenCode couldn't start")
      },
      done: async () => undefined
    })
    const finishing = lifecycle.finishPendingSetup()
    await failing.checked
    failing.fail("OpenCode couldn't migrate its sessions: disk full")
    await finishing
    // Only the failed setup changed anything.
    expect(phases).toEqual(["updating", "failed"])
    expect(lifecycle.isGated("unchecked")).toBe(false)
    expect(lifecycle.isGated("done")).toBe(false)
  })

  it("has nothing to do without harness setup", async () => {
    const { lifecycle } = await makeLifecycle({})
    await lifecycle.finishPendingSetup()
    const bare = makeHarnessLifecycleManager({
      agents: { catalog: [] } as unknown as AgentRuntimeService,
      db: await makeDb()
    })
    await bare.finishPendingSetup()
    expect(bare.isGated("fake-cli")).toBe(false)
  })
})
