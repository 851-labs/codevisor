import { expect, it } from "vitest"

import type { PiSpawnRequest } from "./client.js"
import { makePiProvider } from "./provider.js"
import { definition, environment, run } from "./test-support.js"

it("launches an older Pi without --approve when its CLI doesn't support it", async () => {
  const spawned: Array<PiSpawnRequest> = []
  const provider = makePiProvider(
    { ...environment, supportsFlag: async () => false },
    {
      connector: async (request) => {
        spawned.push(request)
        throw new Error("stop")
      },
      writeExtension: async (name) => `/tmp/${name}.ts`
    }
  )
  await expect(
    run(provider.loadSession(definition, "pi-1", "/project", async () => undefined))
  ).rejects.toThrow("stop")
  expect(spawned[0]?.args).toEqual(["--session", "pi-1"])
})
