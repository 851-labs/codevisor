import {
  FleetSandboxAnswer,
  type FleetSandboxAction,
  type FleetSandboxRequest,
  type Sandbox,
  type SandboxProviderKind
} from "@codevisor/api"
import { Schema } from "effect"

import { HttpFailure } from "../server-context.js"
import type { SandboxDeps } from "./sandboxes.js"

export interface SandboxManagement {
  readonly held: () => boolean
  readonly holder: () => string | undefined
  readonly hostLocal: (provider: SandboxProviderKind) => boolean
  readonly forward: (machineId: string, request: FleetSandboxRequest) => Promise<unknown>
}

export interface RemoteManager {
  readonly machineId: string
}

export type SandboxManager = "here" | RemoteManager

export const IN_PROGRESS: ReadonlySet<Sandbox["state"]> = new Set([
  "creating",
  "bootstrapping",
  "syncing",
  "cloning"
])

const decodeAnswer = Schema.decodeUnknownSync(FleetSandboxAnswer)

export const creatorOf = (deps: Pick<SandboxDeps, "serverId">, machine: Sandbox): string =>
  machine.createdOn ?? deps.serverId

export const createdHere = (deps: Pick<SandboxDeps, "serverId">, machine: Sandbox): boolean =>
  creatorOf(deps, machine) === deps.serverId

export const managerOf = (deps: SandboxDeps, machine: Sandbox): SandboxManager | undefined => {
  if (managedByCreator(deps, machine)) {
    return createdHere(deps, machine) ? "here" : { machineId: creatorOf(deps, machine) }
  }
  if (deps.management.held()) return "here"
  const holder = deps.management.holder()
  return holder === undefined ? undefined : { machineId: holder }
}

export const managesHere = (deps: SandboxDeps, machine: Sandbox): boolean =>
  managerOf(deps, machine) === "here"

export interface SandboxRouting {
  readonly destroy: (id: string) => Promise<void>
  readonly wake: (id: string) => Promise<Sandbox>
  readonly claimWorkspace: (id: string, workspaceId: string) => Promise<Sandbox>
  readonly receive: (request: FleetSandboxRequest) => Promise<FleetSandboxAnswer>
}

export interface SandboxActions {
  readonly destroyHere: (machine: Sandbox) => Promise<undefined>
  readonly wakeHere: (machine: Sandbox) => Promise<Sandbox>
}

export const makeSandboxRouting = (deps: SandboxDeps, actions: SandboxActions): SandboxRouting => {
  const act = (request: FleetSandboxAction, machine: Sandbox): Promise<Sandbox | undefined> => {
    if (request.action === "destroy") return actions.destroyHere(machine)
    if (request.action === "wake") return actions.wakeHere(machine)
    return claimHere(deps, machine, request.workspaceId)
  }

  const routed = async (request: FleetSandboxAction): Promise<Sandbox | undefined> => {
    const machine = await existingSandbox(deps, request.id)
    const manager = managerOf(deps, machine)
    return manager === "here" ? act(request, machine) : forwardToManager(deps, manager, request)
  }

  return {
    destroy: async (id) => {
      await routed({ action: "destroy", id })
    },
    wake: async (id) => claimed(await routed({ action: "wake", id })),
    claimWorkspace: async (id, workspaceId) =>
      claimed(await routed({ action: "claim-workspace", id, workspaceId })),
    receive: async ({ request, record }) => {
      await deps.records.merge([record])
      const machine = await existingSandbox(deps, request.id)
      if (!managesHere(deps, machine)) throw notManagedHere(machine)

      const sandbox = await act(request, machine)
      return {
        ...(sandbox === undefined ? {} : { sandbox }),
        record: await deps.records.entry(request.id)
      }
    }
  }
}

export const existingSandbox = async (deps: SandboxDeps, id: string): Promise<Sandbox> => {
  const machine = await deps.records.get(id)
  if (machine === undefined) throw new HttpFailure(404, `No sandbox ${id}`)
  return machine
}

const claimHere = async (
  deps: SandboxDeps,
  machine: Sandbox,
  workspaceId: string
): Promise<Sandbox> => {
  const wanted = workspaceId.toLowerCase()
  if (machine.workspaceId === wanted) return machine
  if (machine.state !== "ready" || machine.workspaceId !== undefined)
    throw new HttpFailure(409, `${machine.name} can't move to another workspace`)

  const claimedMachine = { ...machine, workspaceId: wanted }
  await deps.records.put(claimedMachine)
  return claimedMachine
}

const claimed = (sandbox: Sandbox | undefined): Sandbox => {
  if (sandbox === undefined)
    throw new HttpFailure(502, "The sandbox manager didn't return the sandbox")
  return sandbox
}

const forwardToManager = async (
  deps: SandboxDeps,
  manager: RemoteManager | undefined,
  request: FleetSandboxAction
): Promise<Sandbox | undefined> => {
  if (manager === undefined) {
    throw new HttpFailure(503, "No machine is managing sandboxes right now. Try again in a minute.")
  }

  const record = await deps.records.entry(request.id)
  const answer = decodeAnswer(await deps.management.forward(manager.machineId, { request, record }))
  await deps.records.merge([answer.record])
  return answer.sandbox
}

const notManagedHere = (machine: Sandbox): HttpFailure =>
  new HttpFailure(409, `This machine doesn't manage ${machine.name} right now`)

const managedByCreator = (deps: SandboxDeps, machine: Sandbox): boolean =>
  IN_PROGRESS.has(machine.state) ||
  machine.state === "archived" ||
  deps.management.hostLocal(machine.provider)
