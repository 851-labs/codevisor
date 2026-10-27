import { makeFakeSandboxProvider, type ExecRequest } from "@codevisor/sandboxes"
import { describe, expect, it } from "vitest"

import { run } from "../server-context.js"
import { makeServices } from "../test-support.js"
import { pushRemainingAgents } from "./sandbox-agents.js"
import { sandboxRemote } from "./sandbox-remote.js"
import { pushOneWaySync } from "./sandbox-sync.js"

const stamp = (wallMs: number) => ({ wallMs, counter: 0, deviceId: "owner" })

const remoteAnswering = (
  answers: ReadonlyArray<{ readonly exitCode: number; readonly stdout: string }>
) => {
  const requests: ExecRequest[] = []
  let harnessReads = 0
  const provider = makeFakeSandboxProvider({
    onExec: (_id, request) => {
      requests.push(request)
      if (!request.script.includes("/v1/harnesses'"))
        return { exitCode: 0, stdout: "{}", stderr: "" }
      const answer = answers[Math.min(harnessReads, answers.length - 1)] ?? {
        exitCode: 0,
        stdout: "[]"
      }
      harnessReads += 1
      return { ...answer, stderr: answer.exitCode === 0 ? "" : "not yet" }
    }
  })
  return { requests, remote: sandboxRemote(provider, "fake-1") }
}

const ready = JSON.stringify([{ id: "codex", readiness: { state: "ready" } }])
const installing = JSON.stringify([{ id: "codex", readiness: { state: "unavailable" } }])

const seeded = async () => {
  const { services } = await makeServices("server-owner")
  await run(
    services.db.mergeSyncEntries("harnesses", [
      { key: "codex", value: { installed: true }, timestamp: stamp(1) },
      { key: "gemini", value: { installed: true }, timestamp: stamp(2) }
    ])
  )
  return services
}

describe("installing the remaining agents on a sandbox", () => {
  it("waits for the chat's agent to be ready, then pushes every agent and reconciles", async () => {
    const services = await seeded()
    const { requests, remote } = remoteAnswering([
      { exitCode: 7, stdout: "" },
      { exitCode: 0, stdout: installing },
      { exitCode: 0, stdout: ready }
    ])
    const sleeps: number[] = []

    await pushRemainingAgents({ db: services.db }, remote, "codex", {
      attempts: 10,
      intervalMs: 50,
      sleep: (ms) => {
        sleeps.push(ms)
        return Promise.resolve()
      }
    })

    expect(sleeps).toEqual([50, 50])
    expect(requests.at(-2)?.stdin).toContain('"gemini"')
    expect(requests.at(-1)?.script).toContain("/v1/sync/harnesses/reconcile")
  })

  it("pushes every agent when the chat's agent has no setting of its own", async () => {
    const services = await seeded()
    const { requests, remote } = remoteAnswering([{ exitCode: 0, stdout: ready }])

    await pushOneWaySync({ db: services.db }, remote, "retired-agent")

    const harnessPut = requests.find((request) => request.script.includes("/v1/sync/harnesses'"))
    expect(harnessPut?.stdin).toContain('"codex"')
    expect(harnessPut?.stdin).toContain('"gemini"')
  })
})
