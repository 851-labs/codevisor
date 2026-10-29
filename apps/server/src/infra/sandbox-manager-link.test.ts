import {
  FLEET_SANDBOX_ACTION_PATH,
  SANDBOX_MANAGER_ROLE,
  type CloudMachinePresence
} from "@codevisor/api"
import type { HeldRole, RoleTask } from "@codevisor/cloud-client"
import { APPLE_CONTAINER_DEFINITION, E2B_DEFINITION, TART_DEFINITION } from "@codevisor/sandboxes"
import { describe, expect, it } from "vitest"

import { HttpFailure } from "../server-context.js"
import { PeerAnswerError } from "./machine-link.js"
import { hostsLocally } from "./sandbox-connections.js"
import {
  joinSandboxManagerElection,
  makeSandboxManagement,
  type SandboxManagerLinkOptions
} from "./sandbox-manager-link.js"
import { presence } from "./sandbox-test-support.js"

const lease: HeldRole = {
  role: SANDBOX_MANAGER_ROLE,
  version: 1,
  signal: new AbortController().signal,
  fence: { role: SANDBOX_MANAGER_ROLE, version: 1 },
  held: () => true
}

interface World {
  holder?: string | undefined
  held: boolean
  presences?: CloudMachinePresence[] | undefined
  invoke?: SandboxManagerLinkOptions["link"]["invoke"]
  readonly runs: Array<[string, RoleTask]>
}

const optionsFor = (world: World): SandboxManagerLinkOptions => ({
  roles: {
    holding: (role) => (world.held && role === SANDBOX_MANAGER_ROLE ? lease : undefined),
    views: () => [
      { role: "other-role", version: 3, held: false, holder: "device-x" },
      {
        role: SANDBOX_MANAGER_ROLE,
        version: 1,
        held: world.held,
        ...(world.holder === undefined ? {} : { holder: world.holder })
      }
    ],
    run: (role, task) => {
      world.runs.push([role, task])
      return () => undefined
    }
  },
  cloud: { deviceId: () => "device-self", machines: () => world.presences },
  link: { invoke: (...args) => world.invoke?.(...args) ?? Promise.resolve(undefined) },
  serverId: "server-self",
  machineName: () => "Studio",
  hostLocal: (provider) => provider === "tart"
})

const failureOf = async (work: Promise<unknown>) => {
  try {
    await work
  } catch (cause) {
    if (cause instanceof HttpFailure) return [cause.status, cause.message]
    throw cause
  }
  throw new Error("Expected a failure")
}

describe("the sandbox manager's link to other machines", () => {
  it("counts a vendor as host-local when one of its fields names the machine that runs it", () => {
    expect(
      [TART_DEFINITION, APPLE_CONTAINER_DEFINITION, E2B_DEFINITION, undefined].map(hostsLocally)
    ).toEqual([true, true, false, false])
  })

  it("finds the holder by its server id, falls back to its cloud id, and isn't its own holder", () => {
    const world: World = {
      held: false,
      holder: "device-mini",
      presences: [presence("device-mini", { serverId: "server-mini" })],
      runs: []
    }
    const management = makeSandboxManagement(optionsFor(world))

    const byServer = management.holder()
    world.presences = undefined
    const byDevice = management.holder()
    world.holder = "device-self"
    const self = management.holder()
    world.holder = undefined

    expect([byServer, byDevice, self, management.holder()]).toEqual([
      "server-mini",
      "cloud:device-mini",
      undefined,
      undefined
    ])
    expect([management.held(), management.hostLocal("tart"), management.hostLocal("e2b")]).toEqual([
      false,
      true,
      false
    ])
    world.held = true
    expect(management.held()).toBe(true)
  })

  it("calls the manager as this machine and keeps the manager's status when it refuses", async () => {
    const calls: unknown[] = []
    const world: World = {
      held: false,
      runs: [],
      invoke: (machine, path, args, origin) => {
        calls.push([machine, path, args, origin])
        return Promise.resolve({ ok: true })
      }
    }
    const management = makeSandboxManagement(optionsFor(world))
    const request = {
      request: { action: "destroy" as const, id: "box" },
      record: { key: "box", value: null, timestamp: { wallMs: 1, counter: 0, deviceId: "d" } }
    }

    const answer = await management.forward("server-mini", request)
    world.invoke = () => Promise.reject(new PeerAnswerError("Busy", {}, 409))
    const refused = await failureOf(management.forward("server-mini", request))
    world.invoke = () => Promise.reject(new Error("Mini is offline"))
    const offline = await failureOf(management.forward("server-mini", request))

    expect(answer).toEqual({ ok: true })
    expect(calls).toEqual([
      [
        "server-mini",
        FLEET_SANDBOX_ACTION_PATH,
        request,
        { machineId: "server-self", machineName: "Studio" }
      ]
    ])
    expect([refused, offline]).toEqual([
      [409, "Busy"],
      [503, "Mini is offline"]
    ])
  })

  it("stands for the role once it knows it isn't a sandbox itself", () => {
    const world: World = { held: false, runs: [] }
    let held = 0
    const join = joinSandboxManagerElection(optionsFor(world), () => {
      held += 1
    })

    const attempts = [join()]
    world.presences = [
      presence("device-self", { ephemeral: { provider: "e2b", ownerDeviceId: "o" } })
    ]
    attempts.push(join())
    const asSandbox = world.runs.length
    world.presences = [presence("device-self")]
    attempts.push(join(), join())
    void world.runs[0]?.[1](lease)

    expect(attempts).toEqual([false, false, true, true])
    expect(asSandbox).toBe(0)
    expect(world.runs.map(([role]) => role)).toEqual([SANDBOX_MANAGER_ROLE])
    expect(held).toBe(1)
  })
})
