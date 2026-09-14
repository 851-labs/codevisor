import { afterEach, expect, it } from "vitest"
import { makeHarnessLifecycleManager } from "./harness-lifecycle.js"
import {
  agentsStub,
  cleanupLifecycleTests,
  fakeSpawner,
  fakeTerminal,
  harness,
  installableDefinition,
  makeBinDir,
  makeDb,
  waitForLifecycleSettle
} from "./harness-lifecycle-test-support.js"

afterEach(cleanupLifecycleTests)

it("explicit checks clear failed operations while preserving active installs", async () => {
  const db = await makeDb()
  const bin = makeBinDir(["npm"])
  const { processes, spawnShell } = fakeSpawner()
  const { terminal } = fakeTerminal()
  const lifecycle = makeHarnessLifecycleManager({
    agents: agentsStub([installableDefinition], []),
    db,
    spawnShell,
    terminal,
    resolveEnv: async () => ({ PATH: bin })
  })
  const inventory = [harness("fake-cli", "/fake/cli", "1.0")]
  await lifecycle.beginInstall("fake-cli", "npm")
  await lifecycle.checkForUpdates(true)
  expect((await lifecycle.decorateHarnesses(inventory))[0]?.lifecycle?.phase).toBe("installing")
  const settled = waitForLifecycleSettle(lifecycle)
  processes[0]?.emitExit(1)
  await settled
  await lifecycle.checkForUpdates()
  expect((await lifecycle.decorateHarnesses(inventory))[0]?.lifecycle?.phase).toBe("failed")
  await lifecycle.checkForUpdates(true)
  expect((await lifecycle.decorateHarnesses(inventory))[0]?.lifecycle).toBeUndefined()
})
