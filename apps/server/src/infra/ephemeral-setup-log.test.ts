import type { EphemeralSetupLog, EphemeralSetupStep } from "@codevisor/api"
import { SIGN_IN_MARKER } from "@codevisor/ephemeral-machines"
import { describe, expect, it, vi } from "vitest"

import { makeEphemeralSetupProgress } from "./ephemeral-setup-log.js"
import { ephemeralHarness } from "./ephemeral-test-support.js"

const request = { provider: "e2b" as const, projectId: "project-1", name: "Spike box" }

const settled = () => new Promise((resolve) => setImmediate(resolve))

const recorder = () => {
  const logs: EphemeralSetupLog[] = []
  let clock = 0
  let steps: ReadonlyArray<EphemeralSetupStep> = []
  const progress = makeEphemeralSetupProgress({
    machineId: "machine-1",
    now: () => `t${clock++}`,
    persist: (next) => {
      steps = next
    },
    publish: (log) => {
      logs.push(log)
      return Promise.resolve()
    }
  })
  return { progress, logs, steps: () => steps }
}

describe("ephemeral setup progress", () => {
  it("splits streamed output into clean lines, and the sign-in marker starts the next stage", async () => {
    const { progress, logs, steps } = recorder()
    progress.stage("install")

    progress.output("stdout", "\u001b[1;32m==>\u001b[0m Downloading\r\n==> Extr")
    progress.output("stdout", `acting\n${SIGN_IN_MARKER}\nStarted`)
    progress.output("stderr", "warning\n\n")
    progress.flush()
    await settled()

    expect(logs.map(({ stage, stream, line }) => [stage, stream, line])).toEqual([
      ["install", "stdout", "==> Downloading"],
      ["install", "stdout", "==> Extracting"],
      ["signIn", "stderr", "warning"],
      ["signIn", "stdout", "Started"]
    ])
    expect(steps().map(({ stage }) => stage)).toEqual(["install", "signIn"])
  })

  it("redacts the invite and closes each step when the next one starts", async () => {
    const { progress, logs, steps } = recorder()
    progress.redact("cvi1.secret")
    progress.redact("")
    progress.stage("create")
    progress.log("joining with cvi1.secret")
    progress.stage("boot")
    progress.finish()
    await settled()

    expect(logs.map(({ line }) => line)).toEqual(["joining with [invite]"])
    expect(steps()).toEqual([
      { stage: "create", startedAt: "t0", endedAt: "t1" },
      { stage: "boot", startedAt: "t1", endedAt: "t2" }
    ])
  })

  it("keeps publishing after one line fails to publish", async () => {
    const published: string[] = []
    const publish = vi
      .fn((log: EphemeralSetupLog) => {
        published.push(log.line)
        return Promise.resolve()
      })
      .mockRejectedValueOnce(new Error("fanout closed"))
    const progress = makeEphemeralSetupProgress({
      machineId: "machine-1",
      now: () => "t",
      persist: () => undefined,
      publish
    })
    progress.stage("sync")

    progress.log("first")
    progress.log("second")
    await settled()

    expect(published).toEqual(["second"])
  })

  it("finishes setting up when saving a step fails once", async () => {
    const harness = await ephemeralHarness()
    const put = harness.records.put.bind(harness.records)
    vi.spyOn(harness.records, "put")
      .mockImplementationOnce(put)
      .mockRejectedValueOnce(new Error("database busy"))
      .mockImplementation(put)

    await harness.machines.create(request)
    await harness.machines.settled()

    expect((await harness.machines.list())[0]?.state).toBe("ready")
  })

  it("prepares the image first and skips installing on a machine whose image already has Codevisor", async () => {
    const harness = await ephemeralHarness({ prepares: true, streams: true })
    const logs: EphemeralSetupLog[] = []
    const publish = (log: EphemeralSetupLog) => {
      logs.push(log)
      return Promise.resolve()
    }

    await harness.machines.create(request, publish)
    await harness.machines.settled()

    const machine = (await harness.machines.list())[0]
    expect(machine?.plan).toEqual(["image", "create", "signIn", "sync", "clone"])
    expect(machine?.steps?.map(({ stage }) => stage)).toEqual(machine?.plan)
    expect(logs[0]).toMatchObject({ stage: "image", line: "Preparing the fake image" })
    const bootstrap = harness.provider.execs.find((exec) =>
      exec.request.script.includes("auth login --invite")
    )
    expect(bootstrap?.request.script).not.toContain("installer")
  })

  it("publishes what each stage prints, in order, for the machine the client named", async () => {
    const harness = await ephemeralHarness({ boots: true, streams: true })
    const logs: EphemeralSetupLog[] = []
    const publish = (log: EphemeralSetupLog) => {
      logs.push(log)
      return Promise.resolve()
    }

    await harness.machines.create({ ...request, id: "CLIENT-ID" }, publish)
    await harness.machines.settled()

    const machine = (await harness.machines.list())[0]
    expect(machine?.id).toBe("client-id")
    expect(machine?.steps?.map(({ stage }) => stage)).toEqual(machine?.plan)
    expect(logs.every(({ machineId }) => machineId === "client-id")).toBe(true)
    expect(logs.map(({ stage, line }) => `${stage}: ${line}`)).toEqual([
      "create: Creating a Fake machine",
      "boot: Booting fake-1",
      "install: installed",
      "signIn: joined",
      "signIn: Waiting for Spike box to join your account",
      "signIn: Spike box joined your account",
      "sync: Pushed 0 settings",
      "clone: Cloning https://github.com/851-labs/codevisor.git",
      "clone: codevisor is ready"
    ])
    await expect(harness.machines.create({ ...request, id: "client-id" })).rejects.toMatchObject({
      status: 409
    })
  })
})
