import { mkdtempSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { waitFor } from "./changes-test-support.js"
import type { RunningCodevisorServer } from "./server.js"
import { jsonRequest, run, runningServers, tempDirs } from "./test-support.js"
import { field } from "./unknown-values.js"

export const restartStatePaths = () => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-drain-state-"))
  tempDirs.push(root)
  return {
    restartSnapshotPath: join(root, "restart-resume.json"),
    pausedTurnsPath: join(root, "paused-for-update.json")
  }
}

export const stopServer = async (server: RunningCodevisorServer): Promise<void> => {
  runningServers.splice(runningServers.indexOf(server), 1)
  await run(server.close)
}

export const pauseForUpdate = async (server: RunningCodevisorServer): Promise<void> => {
  await jsonRequest(server, "/v1/restart/drain", { method: "POST" })
  await waitFor(
    async () => field((await jsonRequest(server, "/v1/restart/drain")).body, "state") === "drained"
  )
}
