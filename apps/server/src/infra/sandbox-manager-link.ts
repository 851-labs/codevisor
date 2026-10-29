import {
  FLEET_SANDBOX_ACTION_PATH,
  SANDBOX_MANAGER_ROLE,
  type CloudMachinePresence,
  type SandboxProviderKind
} from "@codevisor/api"
import type { MachineRoles } from "@codevisor/cloud-client"

import { failureMessage, HttpFailure } from "../server-context.js"
import { PeerAnswerError, type MachineLink } from "./machine-link.js"
import type { SandboxManagement } from "./sandbox-manager.js"

export interface SandboxManagerLinkOptions {
  readonly roles: Pick<MachineRoles, "holding" | "views" | "run">
  readonly cloud: {
    readonly deviceId: () => string | undefined
    readonly machines: () => ReadonlyArray<CloudMachinePresence> | undefined
  }
  readonly link: Pick<MachineLink, "invoke">
  readonly serverId: string
  readonly machineName: () => string
  readonly hostLocal: (provider: SandboxProviderKind) => boolean
}

export const makeSandboxManagement = (options: SandboxManagerLinkOptions): SandboxManagement => ({
  held: () => options.roles.holding(SANDBOX_MANAGER_ROLE) !== undefined,
  holder: () => holderMachineId(options),
  hostLocal: options.hostLocal,
  forward: async (machineId, request) => {
    try {
      return await options.link.invoke(machineId, FLEET_SANDBOX_ACTION_PATH, request, {
        machineId: options.serverId,
        machineName: options.machineName()
      })
    } catch (cause) {
      if (cause instanceof PeerAnswerError) throw new HttpFailure(cause.status, cause.message)
      throw new HttpFailure(503, failureMessage(cause))
    }
  }
})

export const joinSandboxManagerElection = (
  options: Pick<SandboxManagerLinkOptions, "roles" | "cloud">,
  onHeld: () => void
): (() => boolean) => {
  let joined = false
  return () => {
    if (joined || !isAlwaysPresent(options.cloud)) return joined
    joined = true
    options.roles.run(SANDBOX_MANAGER_ROLE, onHeld)
    return joined
  }
}

const isAlwaysPresent = (cloud: SandboxManagerLinkOptions["cloud"]): boolean => {
  const self = selfPresence(cloud)
  return self !== undefined && self.ephemeral === undefined
}

const selfPresence = (cloud: SandboxManagerLinkOptions["cloud"]) => {
  const deviceId = cloud.deviceId()
  return cloud.machines()?.find((presence) => presence.deviceId === deviceId)
}

const holderMachineId = (options: SandboxManagerLinkOptions): string | undefined => {
  const holder = options.roles.views().find((view) => view.role === SANDBOX_MANAGER_ROLE)?.holder
  if (holder === undefined || holder === options.cloud.deviceId()) return undefined

  const presence = options.cloud.machines()?.find((machine) => machine.deviceId === holder)
  return presence?.serverId ?? `cloud:${holder}`
}
