import type { ExecRequest } from "@codevisor/ephemeral-machines"
import { describe, expect, it } from "vitest"

import { run } from "../server-context.js"
import { ephemeralHarness } from "./ephemeral-test-support.js"

const request = { provider: "e2b" as const, projectId: "project-1", name: "Spike box" }
const stamp = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "owner" })

const isHarnessPush = (curl: ExecRequest): boolean =>
  curl.script.includes("-X 'PUT'") && curl.script.includes("/v1/sync/harnesses'")

const harnessPushes = (curls: ReadonlyArray<ExecRequest>): ReadonlyArray<ReadonlyArray<string>> =>
  curls.filter(isHarnessPush).map((curl) => keysOf(curl.stdin ?? ""))

const keysOf = (body: string): ReadonlyArray<string> =>
  [...body.matchAll(/"key":"([^"]+)"/g)].map((match) => match[1] ?? "").toSorted()

describe("starting a machine before the first send", () => {
  it("installs the chat's agent first and the rest once the machine is ready", async () => {
    const harness = await ephemeralHarness()
    await run(
      harness.services.db.mergeSyncEntries("harnesses", [
        { key: "codex", value: { installed: true }, timestamp: stamp(1) },
        { key: "claude-code", value: { installed: true }, timestamp: stamp(2) }
      ])
    )

    await harness.machines.create({ ...request, harnessId: "codex" })
    await harness.machines.settled()

    expect(harnessPushes(harness.curls)).toEqual([["codex"], ["claude-code", "codex"]])
    expect(harness.curls.at(-1)?.script).toContain("/v1/sync/harnesses/reconcile")
  })

  it("leaves the workspace for the chat to claim once the machine is ready", async () => {
    const harness = await ephemeralHarness()
    await harness.machines.create({ ...request, defersWorkspace: true })
    await harness.machines.settled()
    const [machine] = await harness.machines.list()

    expect(machine).toMatchObject({ state: "ready", defersWorkspace: true })
    expect(machine?.workspaceId).toBeUndefined()
    expect(harness.toolCalls.map(({ tool }) => tool)).not.toContain("codevisor.workspaces.upsert")

    const claimed = await harness.machines.claimWorkspace("id-1", "WORKSPACE-1")

    expect(claimed.workspaceId).toBe("workspace-1")
    expect(await harness.machines.claimWorkspace("id-1", "workspace-1")).toEqual(claimed)
    await expect(harness.machines.claimWorkspace("id-1", "workspace-2")).rejects.toMatchObject({
      status: 409
    })
    await expect(harness.machines.claimWorkspace("missing", "workspace-1")).rejects.toMatchObject({
      status: 404
    })
  })

  it("keeps the machine when the remaining agents can't be pushed", async () => {
    let harnessPuts = 0
    const harness = await ephemeralHarness({
      onCurl: (curl) => {
        if (isHarnessPush(curl)) harnessPuts += 1
        const fails = isHarnessPush(curl) && harnessPuts === 2
        return { exitCode: fails ? 7 : 0, stdout: "{}", stderr: fails ? "connection reset" : "" }
      }
    })

    await harness.machines.create({ ...request, harnessId: "codex" })
    await harness.machines.settled()

    expect((await harness.machines.list())[0]?.state).toBe("ready")
    expect(harness.logs.at(-1)).toContain("Installing the remaining agents failed")
  })

  it("won't hand a machine to a workspace before it is ready", async () => {
    const harness = await ephemeralHarness()
    await harness.machines.create({ ...request, defersWorkspace: true })

    await expect(harness.machines.claimWorkspace("id-1", "workspace-1")).rejects.toMatchObject({
      status: 409
    })
    await harness.machines.settled()
  })
})
