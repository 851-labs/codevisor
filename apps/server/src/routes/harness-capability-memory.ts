import { AgentRuntimeError } from "@codevisor/agent-runtime"
import type { HarnessCapability } from "@codevisor/api"

export interface CapabilityRequest {
  readonly harnessId: string
  readonly accountId: string | undefined
  readonly cwd: string
  readonly configSelections: Readonly<Record<string, string>> | undefined
}

export interface CapabilityMemory {
  readonly remember: (request: CapabilityRequest, capability: HarnessCapability) => void
  readonly recall: (request: CapabilityRequest) => HarnessCapability | undefined
}

export const REMEMBERED_CAPABILITY_LIMIT = 64

export const makeCapabilityMemory = (): CapabilityMemory => {
  const remembered = new Map<string, HarnessCapability>()
  return {
    remember: (request, capability) => {
      const key = capabilityKey(request)
      remembered.delete(key)
      remembered.set(key, capability)
      forgetOldest(remembered)
    },
    recall: (request) => remembered.get(capabilityKey(request))
  }
}

export const inspectionTimedOut = (cause: unknown): boolean =>
  cause instanceof AgentRuntimeError && cause.timedOut === true

const forgetOldest = (remembered: Map<string, HarnessCapability>): void => {
  for (const oldest of remembered.keys()) {
    if (remembered.size <= REMEMBERED_CAPABILITY_LIMIT) return
    remembered.delete(oldest)
  }
}

const capabilityKey = ({ harnessId, accountId, cwd, configSelections }: CapabilityRequest) =>
  JSON.stringify([harnessId, accountId ?? null, cwd, sortedSelections(configSelections)])

const sortedSelections = (configSelections: CapabilityRequest["configSelections"]) =>
  Object.entries(configSelections ?? {}).toSorted(([left], [right]) => left.localeCompare(right))
