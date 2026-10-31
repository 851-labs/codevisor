import { describe, expect, it } from "vitest"

import { readProfileOptions } from "./options.js"
import { SandboxProviderError, type ProvisionProgress } from "./provider.js"
import {
  makeTartOrchardProvider,
  TART_ORCHARD_DEFINITION,
  TART_VMS_RESOURCE,
  tartOrchardAdapter,
  type OrchardControllerInfo,
  type OrchardExecOutcome,
  type OrchardVm,
  type OrchardWorker,
  type TartOrchardClient,
  type TartOrchardCredentials
} from "./tart-orchard.js"

const spec = { name: "box", tags: { owner: "device-a", machine: "m1" } }
const machineName = "codevisor_device-a_m1"
const image = "ghcr.io/cirruslabs/macos-tahoe-base:latest"
const profile = readProfileOptions(TART_ORCHARD_DEFINITION, {})

interface FakeSetup {
  readonly info?: OrchardControllerInfo
  readonly statuses?: ReadonlyArray<OrchardVm | undefined>
  readonly vms?: ReadonlyArray<OrchardVm>
  readonly workers?: ReadonlyArray<OrchardWorker>
  readonly outcomes?: ReadonlyArray<OrchardExecOutcome>
  readonly forwardFailures?: number
}

const exited = (exitCode: number, stdout = "", stderr = ""): OrchardExecOutcome => ({
  kind: "exited",
  exitCode,
  stdout,
  stderr
})

const vm = (status: string, details: Partial<OrchardVm> = {}): OrchardVm => ({
  name: machineName,
  status,
  resources: { [TART_VMS_RESOURCE]: 1 },
  ...details
})

const worker = (name: string, slots: number, schedulingPaused = false): OrchardWorker => ({
  name,
  schedulingPaused,
  resources: { [TART_VMS_RESOURCE]: slots }
})

const fakeOrchard = (setup: FakeSetup = {}) => {
  const calls: unknown[] = []
  const statuses = [...(setup.statuses ?? [])]
  const outcomes = [...(setup.outcomes ?? [])]
  let forwardFailures = setup.forwardFailures ?? 0
  let forwardsOpened = 0
  const client: TartOrchardClient = {
    controllerInfo: () => Promise.resolve(setup.info ?? {}),
    createVm: (vmSpec) => {
      calls.push({ createVm: vmSpec })
      return Promise.resolve()
    },
    getVm: (name) => {
      calls.push({ getVm: name })
      return Promise.resolve(statuses.length > 1 ? statuses.shift() : statuses[0])
    },
    listVms: () => Promise.resolve(setup.vms ?? []),
    deleteVm: (name) => {
      calls.push({ deleteVm: name })
      return Promise.resolve()
    },
    listWorkers: () => Promise.resolve(setup.workers ?? []),
    exec: (name, request) => {
      calls.push({ exec: name, ...request })
      return Promise.resolve(outcomes.shift() ?? exited(0))
    },
    forwardPort: (name, port) => {
      calls.push({ forwardPort: name, port })
      if (forwardFailures > 0) {
        forwardFailures -= 1
        return Promise.reject(new Error("listen failed"))
      }
      forwardsOpened += 1
      const localPort = 50_000 + forwardsOpened
      return Promise.resolve({
        host: "127.0.0.1",
        port: localPort,
        close: () => {
          calls.push({ closeForward: localPort })
          return Promise.resolve()
        }
      })
    }
  }
  return { client, calls }
}

const fakeClock = () => {
  let now = Date.parse("2026-10-26T00:00:00Z")
  const sleeps: number[] = []
  const clock = {
    now: () => now,
    sleep: (ms: number) => {
      sleeps.push(ms)
      now += ms
      return Promise.resolve()
    }
  }
  return { clock, sleeps }
}

const recordingProgress = () => {
  const events: string[] = []
  const progress: ProvisionProgress = {
    stage: (stage) => events.push(`stage:${stage}`),
    log: (line) => events.push(line),
    output: (stream, text) => events.push(`${stream}:${text}`)
  }
  return { events, progress }
}

const createCalls = (calls: ReadonlyArray<unknown>) =>
  calls.filter((call) => typeof call === "object" && call !== null && "createVm" in call)

const account = {
  controllerUrl: "https://orchard.example.com:6120",
  serviceAccountName: "codevisor",
  serviceAccountToken: "token"
}

const connecting = (info: OrchardControllerInfo = {}) => {
  const seen: TartOrchardCredentials[] = []
  const { client } = fakeOrchard({ info })
  const adapter = tartOrchardAdapter((credentials) => {
    seen.push(credentials)
    return client
  })
  return { adapter, seen }
}

const ignoreOutput = (): void => undefined

const stateOf = async (status: OrchardVm | undefined) =>
  (await makeTartOrchardProvider(fakeOrchard({ statuses: [status] }).client).status(machineName))
    .state

const availability = (workers: ReadonlyArray<OrchardWorker>, vms: ReadonlyArray<OrchardVm>) =>
  makeTartOrchardProvider(fakeOrchard({ workers, vms }).client).availability?.(profile)

describe("Tart Orchard adapter", () => {
  it("connects with the service account and an optional certificate fingerprint", () => {
    const { adapter, seen } = connecting()

    adapter.connect(account)
    adapter.connect({ ...account, certificateFingerprint: "AB CD" })

    expect(seen).toEqual([account, { ...account, certificateFingerprint: "AB CD" }])
  })

  it("verifies the account by naming the controller's Orchard version", async () => {
    expect(await connecting({ version: "0.58.0" }).adapter.verify?.(account)).toEqual({
      identity: "Orchard 0.58.0"
    })
  })

  it("verifies without an identity when the controller's version is unknown", async () => {
    expect(await connecting({ version: "unknown" }).adapter.verify?.(account)).toEqual({})
    expect(await connecting().adapter.verify?.(account)).toEqual({})
  })

  it("rejects controllers older than the exec endpoint", async () => {
    await expect(connecting({ version: "0.50.1" }).adapter.verify?.(account)).rejects.toThrow(
      "This controller runs Orchard 0.50.1; Codevisor needs Orchard 0.51.0 or later"
    )
  })
})

describe("Tart Orchard provider create", () => {
  it("creates a headless macOS VM, waits for it to run and for SSH, then returns it", async () => {
    const { client, calls } = fakeOrchard({
      statuses: [
        vm("pending"),
        vm("pending"),
        vm("pending", { worker: "mac-1" }),
        vm("pending", { worker: "mac-1", statusMessage: "pulling the image" }),
        vm("running", { worker: "mac-1" })
      ]
    })
    const { clock, sleeps } = fakeClock()
    const { events, progress } = recordingProgress()
    const options = readProfileOptions(TART_ORCHARD_DEFINITION, {
      cpu: 6,
      memoryGiB: 16,
      diskSizeGB: 120,
      password: "secret"
    })

    const created = await makeTartOrchardProvider(client, clock).create(spec, options, progress)

    expect(created).toEqual({ providerMachineId: machineName, platform: "darwin" })
    expect(createCalls(calls)).toEqual([
      {
        createVm: {
          name: machineName,
          os: "darwin",
          image,
          cpu: 6,
          memory: 16_384,
          diskSize: 120,
          headless: true,
          username: "admin",
          password: "secret"
        }
      }
    ])
    expect(sleeps).toEqual([2000, 2000, 2000, 2000])
    expect(events).toEqual([
      `Creating Orchard VM ${machineName} from ${image}`,
      "Waiting for an Orchard worker with a free macOS VM slot",
      "Starting on Orchard worker mac-1",
      "pulling the image",
      "stage:boot",
      "Waiting for SSH",
      "SSH is ready"
    ])
    expect(calls.at(-1)).toEqual({
      exec: machineName,
      command: "true",
      waitSeconds: 180,
      timeoutMs: 210_000
    })
  })

  it("leaves the disk size to the image when none is chosen", async () => {
    const { client, calls } = fakeOrchard({ statuses: [vm("running")] })

    await makeTartOrchardProvider(client, fakeClock().clock).create(spec, profile)

    expect(createCalls(calls)).toHaveLength(1)
    expect(createCalls(calls)[0]).not.toHaveProperty(["createVm", "diskSize"])
  })

  it("deletes a VM that fails to start and reports Orchard's reason", async () => {
    const { client, calls } = fakeOrchard({
      statuses: [vm("pending"), vm("failed", { statusMessage: "image pull failed" })]
    })

    await expect(
      makeTartOrchardProvider(client, fakeClock().clock).create(spec, profile)
    ).rejects.toThrow(`Orchard VM ${machineName} failed: image pull failed`)
    expect(calls.at(-1)).toEqual({ deleteVm: machineName })
  })

  it("reports a failed VM without a status message", async () => {
    const { client } = fakeOrchard({ statuses: [vm("failed")] })

    await expect(
      makeTartOrchardProvider(client, fakeClock().clock).create(spec, profile)
    ).rejects.toThrow(`Orchard VM ${machineName} failed: no reason given`)
  })

  it("fails when the VM disappears while starting", async () => {
    const { client, calls } = fakeOrchard({ statuses: [vm("pending"), undefined] })

    await expect(
      makeTartOrchardProvider(client, fakeClock().clock).create(spec, profile)
    ).rejects.toThrow(`Orchard VM ${machineName} disappeared`)
    expect(calls.at(-1)).toEqual({ deleteVm: machineName })
  })

  it("gives up on a VM still pending after an hour and deletes it", async () => {
    const { client, calls } = fakeOrchard({ statuses: [vm("pending")] })
    const { clock, sleeps } = fakeClock()

    await expect(makeTartOrchardProvider(client, clock).create(spec, profile)).rejects.toThrow(
      `Orchard VM ${machineName} did not start within 60 minutes`
    )
    expect(sleeps).toHaveLength(1800)
    expect(calls.at(-1)).toEqual({ deleteVm: machineName })
  })

  it("deletes the VM when SSH never accepts the image's credentials", async () => {
    const { client, calls } = fakeOrchard({
      statuses: [vm("running")],
      outcomes: [exited(255, "", "Permission denied\n")]
    })

    await expect(
      makeTartOrchardProvider(client, fakeClock().clock).create(spec, profile)
    ).rejects.toThrow(`SSH into Orchard VM ${machineName} failed (exit 255): Permission denied`)
    expect(calls.at(-1)).toEqual({ deleteVm: machineName })
  })

  it("deletes the VM when Orchard can't open an SSH session", async () => {
    const { client, calls } = fakeOrchard({
      statuses: [vm("running")],
      outcomes: [{ kind: "failed", message: "no SSH", stdout: "", stderr: "" }]
    })

    await expect(
      makeTartOrchardProvider(client, fakeClock().clock).create(spec, profile)
    ).rejects.toThrow("Orchard couldn't run the command: no SSH")
    expect(calls.at(-1)).toEqual({ deleteVm: machineName })
  })
})

describe("Tart Orchard provider exec", () => {
  it("runs the script with sh -c and returns non-zero exits without throwing", async () => {
    const { client, calls } = fakeOrchard({ outcomes: [exited(3, "out", "err")] })

    const result = await makeTartOrchardProvider(client).exec(machineName, {
      script: "echo 'hi'",
      stdin: "invite\n",
      onOutput: ignoreOutput
    })

    expect(result).toEqual({ exitCode: 3, stdout: "out", stderr: "err" })
    expect(calls).toEqual([
      {
        exec: machineName,
        command: `sh -c 'echo '\\''hi'\\'''`,
        stdin: "invite\n",
        waitSeconds: 60,
        timeoutMs: 600_000,
        onOutput: ignoreOutput
      }
    ])
  })

  it("passes the caller's timeout and reports a timed out command as exit 124", async () => {
    const { client, calls } = fakeOrchard({
      outcomes: [{ kind: "timedOut", stdout: "partial", stderr: "warn\n" }]
    })

    const result = await makeTartOrchardProvider(client).exec(machineName, {
      script: "sleep 100",
      timeoutMs: 5000
    })

    expect(result).toEqual({
      exitCode: 124,
      stdout: "partial",
      stderr: "warn\nThe command timed out and Codevisor disconnected from it\n"
    })
    expect(calls).toEqual([
      { exec: machineName, command: "sh -c 'sleep 100'", waitSeconds: 60, timeoutMs: 5000 }
    ])
  })

  it("throws when Orchard reports an error instead of an exit code", async () => {
    const { client } = fakeOrchard({
      outcomes: [{ kind: "failed", message: "SSH session closed", stdout: "", stderr: "" }]
    })

    await expect(
      makeTartOrchardProvider(client).exec(machineName, { script: "id" })
    ).rejects.toThrow(
      new SandboxProviderError(
        "tart-orchard",
        "Orchard couldn't run the command: SSH session closed"
      )
    )
  })
})

describe("Tart Orchard provider status and listing", () => {
  it("maps Orchard VM statuses to machine states", async () => {
    expect(await stateOf(vm("running"))).toBe("running")
    expect(await stateOf(vm("pending"))).toBe("starting")
    expect(await stateOf(vm("failed"))).toBe("stopped")
    expect(await stateOf(undefined)).toBe("gone")
  })

  it("lists only this owner's Codevisor VMs", async () => {
    const { client } = fakeOrchard({
      vms: [
        vm("running"),
        vm("running", { name: "codevisor_device-b_m2" }),
        vm("running", { name: "codevisor_broken" }),
        vm("running", { name: "ci-runner" })
      ]
    })

    expect(await makeTartOrchardProvider(client).list("device-a")).toEqual([
      { providerMachineId: machineName, tags: { owner: "device-a", machine: "m1" } }
    ])
  })
})

describe("Tart Orchard provider destroy and gui", () => {
  it("deletes the VM on destroy", async () => {
    const { client, calls } = fakeOrchard()

    await makeTartOrchardProvider(client).destroy(machineName)

    expect(calls).toEqual([{ deleteVm: machineName }])
  })

  it("forwards VNC through the controller once and closes the forward on destroy", async () => {
    const { client, calls } = fakeOrchard()
    const provider = makeTartOrchardProvider(client)

    expect(await provider.gui?.(machineName)).toEqual({ vncUrl: "vnc://127.0.0.1:50001" })
    expect(await provider.gui?.(machineName)).toEqual({ vncUrl: "vnc://127.0.0.1:50001" })
    await provider.destroy(machineName)

    expect(calls).toEqual([
      { forwardPort: machineName, port: 5900 },
      { closeForward: 50_001 },
      { deleteVm: machineName }
    ])
  })

  it("opens a new forward after a failed one", async () => {
    const { client } = fakeOrchard({ forwardFailures: 1 })
    const provider = makeTartOrchardProvider(client)

    await expect(provider.gui?.(machineName)).rejects.toThrow("listen failed")
    expect(await provider.gui?.(machineName)).toEqual({ vncUrl: "vnc://127.0.0.1:50001" })
  })
})

describe("Tart Orchard provider availability", () => {
  it("is available while a worker has a free macOS VM slot", async () => {
    expect(
      await availability(
        [worker("mac-1", 2), worker("mac-2", 2)],
        [
          vm("running", { worker: "mac-1" }),
          vm("running", { worker: "mac-1" }),
          vm("running", { worker: "mac-2" })
        ]
      )
    ).toBeUndefined()
  })

  it("explains when no worker accepts new VMs", async () => {
    expect(await availability([], [])).toBe("No Orchard worker is accepting new VMs")
    expect(await availability([worker("mac-1", 2, true)], [])).toBe(
      "No Orchard worker is accepting new VMs"
    )
  })

  it("explains when running and queued VMs take every macOS slot", async () => {
    const full = "Every macOS VM slot on the Orchard workers is taken"

    expect(
      await availability(
        [worker("mac-1", 2)],
        [vm("running", { worker: "mac-1" }), vm("running", { worker: "mac-1" })]
      )
    ).toBe(full)
    expect(
      await availability([worker("mac-1", 2)], [vm("running", { worker: "mac-1" }), vm("pending")])
    ).toBe(full)
  })

  it("counts only the macOS VM slots that workers and VMs declare", async () => {
    const linuxWorker = { name: "linux-1", schedulingPaused: false, resources: {} }
    const linuxVm = vm("running", { worker: "mac-1", resources: {} })

    expect(await availability([linuxWorker], [])).toBe(
      "Every macOS VM slot on the Orchard workers is taken"
    )
    expect(await availability([worker("mac-1", 1)], [linuxVm])).toBeUndefined()
  })
})
