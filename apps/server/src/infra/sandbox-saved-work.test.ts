import type { ExecRequest, ExecResult } from "@codevisor/sandboxes"
import { describe, expect, it } from "vitest"

import {
  ok,
  restoresWork,
  sandboxHarness,
  SAVED_WORK,
  savesWork,
  type SandboxHarnessOptions
} from "./sandbox-test-support.js"

const request = { profileId: "profile-1", projectId: "project-1", name: "Spike box" }

const refused = (error: string): ExecResult => ({
  exitCode: 22,
  stdout: JSON.stringify({ error }),
  stderr: "curl: (22) The requested URL returned error"
})

const archived = async (options: SandboxHarnessOptions = {}) => {
  const harness = await sandboxHarness(options)
  await harness.machines.create(request)
  await harness.machines.settled()
  const workspace = harness.workspaces[0]
  if (workspace === undefined) throw new Error("No workspace was placed")
  workspace.isArchived = true
  await harness.machines.watch()
  return harness
}

type Harness = Awaited<ReturnType<typeof archived>>

const restored = async (harness: Harness) => {
  await harness.machines.restore("id-2")
  await harness.machines.settled()
  const [machine] = await harness.machines.list()
  if (machine === undefined) throw new Error("No sandbox was restored")
  const lines = (await harness.machines.log(machine.id)).map((log) => log.line)
  return { machine, lines }
}

const lastClone = (harness: Harness) =>
  harness.toolCalls.findLast((call) => call.tool === "codevisor.projects.clone")?.args

const workPutBack = (harness: Harness): ReadonlyArray<unknown> =>
  harness.curls.filter(restoresWork).map((curl) => JSON.parse(curl.stdin ?? "") as unknown)

describe("a sandbox's work across archive and restore", () => {
  it("is saved on this Mac at archive and put back on the restored sandbox's clone", async () => {
    const harness = await archived()
    const archive = await harness.machines.list()
    const kept = await harness.deps.savedWork.get("id-2")

    const { machine, lines } = await restored(harness)

    expect(archive).toMatchObject([{ state: "archived", hasSavedWork: true }])
    expect(kept).toEqual(SAVED_WORK)
    expect(machine).toMatchObject({ state: "ready", workspaceId: "id-2" })
    expect(lastClone(harness)).toMatchObject({ startsOnNewBranch: false })
    expect(workPutBack(harness)).toEqual([SAVED_WORK])
    expect(lines).toContain("Brought back codevisor/pear with its unpushed work")
    expect(await harness.deps.savedWork.get("id-2")).toBeUndefined()
  })

  it("starts the restored sandbox on a new branch and says why when its work couldn't be saved", async () => {
    const harness = await archived({
      onCurl: (curl) => (savesWork(curl) ? refused("Route not found") : ok())
    })
    const reason =
      "Its branch and unpushed work couldn't be saved when it was archived: POST /v1/projects/remote-project/saved-work failed on the sandbox: curl: (22) The requested URL returned error: Route not found"
    const archive = await harness.machines.list()

    const { machine, lines } = await restored(harness)

    expect(archive).toMatchObject([{ state: "archived", workLost: reason }])
    expect(harness.logs).toContain(`Sandbox Spike box (id-1): ${reason}`)
    expect(machine.state).toBe("ready")
    expect(lastClone(harness)).toMatchObject({ startsOnNewBranch: true })
    expect(workPutBack(harness)).toEqual([])
    expect(lines).toContain(
      `Its earlier branch and unpushed work weren't kept, so it starts on a new branch. ${reason}`
    )
  })

  it("fails the restore instead of starting empty when the saved work isn't on this Mac", async () => {
    const harness = await archived()
    await harness.deps.savedWork.remove("id-2")

    const { machine } = await restored(harness)

    expect(machine).toMatchObject({
      state: "failed",
      error:
        "The work Spike box had before it was archived isn't on this Mac. Restore it from the Mac that archived it."
    })
    expect(workPutBack(harness)).toEqual([])
  })

  it("keeps the saved work when the sandbox refuses it, so retrying puts it back", async () => {
    let refusals = 1
    const onCurl = (curl: ExecRequest): ExecResult => {
      if (savesWork(curl)) return ok(JSON.stringify(SAVED_WORK))
      if (!restoresWork(curl) || refusals === 0) return ok()
      refusals -= 1
      return refused("Repository lacks these prerequisite commits")
    }
    const harness = await archived({ onCurl })

    const { machine: failed } = await restored(harness)
    const keptAfterFailure = await harness.deps.savedWork.get("id-2")
    await harness.machines.retry(failed.id)
    await harness.machines.settled()

    expect(failed).toMatchObject({
      state: "failed",
      error:
        "PUT /v1/projects/remote-project/saved-work failed on the sandbox: curl: (22) The requested URL returned error: Repository lacks these prerequisite commits"
    })
    expect(keptAfterFailure).toEqual(SAVED_WORK)
    expect(await harness.machines.list()).toMatchObject([{ state: "ready", workspaceId: "id-2" }])
    expect(workPutBack(harness)).toEqual([SAVED_WORK, SAVED_WORK])
    expect(await harness.deps.savedWork.get("id-2")).toBeUndefined()
  })
})
