import { tmpdir } from "node:os"

import type { AgentSessionMetadata } from "@codevisor/agent-runtime"
import type { Harness, HarnessCapability } from "@codevisor/api"

import { decorateHarnessSettings } from "../infra/harness-preferences.js"
import type { CodevisorServerServices } from "../server-context.js"
import { existingDirectory, run } from "../server-http.js"
import {
  inspectionTimedOut,
  makeCapabilityMemory,
  type CapabilityMemory,
  type CapabilityRequest
} from "./harness-capability-memory.js"
import { conflictFrom } from "./harness-errors.js"

export const discoverCapabilities = async (
  services: CodevisorServerServices,
  url: URL
): Promise<{ readonly harnesses: ReadonlyArray<HarnessCapability> }> => {
  const cwd = existingDirectory(url.searchParams.get("cwd")) ?? tmpdir()
  const requestedHarnessId = url.searchParams.get("harnessId")?.trim() || undefined
  const requestedConfigSelections = capabilityConfigSelections(url)
  const harnesses = await discoverHarnesses(services, false, requestedHarnessId)
  const readyHarnesses = harnesses.filter(
    (harness) => harness.enabled && harness.readiness.state === "ready"
  )
  const pendingCapabilities = pendingSignInCapabilities(harnesses)
  return {
    harnesses: await Promise.all(
      readyHarnesses.map((harness) =>
        inspectHarnessCapability(
          services,
          harness,
          cwd,
          requestedHarnessId,
          requestedConfigSelections
        )
      )
    ).then((inspected) => [...inspected, ...pendingCapabilities])
  }
}

const capabilityConfigSelections = (url: URL): Record<string, string> => {
  return Object.fromEntries(
    [...url.searchParams.entries()].flatMap(([key, value]) =>
      key.startsWith("config.") && key.length > "config.".length
        ? [[key.slice("config.".length), value] as const]
        : []
    )
  )
}

const pendingSignInCapabilities = (
  harnesses: ReadonlyArray<Harness>
): ReadonlyArray<HarnessCapability> => {
  const signInPending = harnesses.filter(
    (harness) =>
      !harness.enabled && harness.desiredEnabled === true && harness.readiness.state === "ready"
  )
  return signInPending.map((harness) => ({
    harness,
    configOptions: []
  }))
}

const capabilityFromMetadata = (
  harness: Harness,
  metadata: AgentSessionMetadata
): HarnessCapability => {
  return {
    harness,
    ...(metadata.modes === undefined ? {} : { modes: metadata.modes }),
    configOptions: metadata.configOptions,
    ...(metadata.supportsGoals === undefined ? {} : { supportsGoals: metadata.supportsGoals }),
    ...(metadata.supportsSteering === undefined
      ? {}
      : { supportsSteering: metadata.supportsSteering }),
    ...(metadata.skills === undefined ? {} : { skills: metadata.skills }),
    ...(metadata.unappliedConfigSelections === undefined
      ? {}
      : { unappliedConfigSelections: metadata.unappliedConfigSelections })
  }
}

const capabilityMemories = new WeakMap<CodevisorServerServices, CapabilityMemory>()

const capabilityMemory = (services: CodevisorServerServices): CapabilityMemory => {
  let memory = capabilityMemories.get(services)
  if (memory === undefined) {
    memory = makeCapabilityMemory()
    capabilityMemories.set(services, memory)
  }
  return memory
}

const failedHarnessCapability = (harness: Harness, cause: unknown): HarnessCapability => {
  console.error(
    `[harnesses] inspecting ${harness.id} failed; it will be missing from the model picker: ${conflictFrom(cause).message}`
  )
  return {
    harness,
    configOptions: []
  }
}

const rememberedHarnessCapability = (
  harness: Harness,
  cause: unknown,
  remembered: HarnessCapability
): HarnessCapability => {
  console.error(
    `[harnesses] inspecting ${harness.id} failed; showing its last known models: ${conflictFrom(cause).message}`
  )
  return { ...remembered, harness }
}

const inspectHarnessCapability = async (
  services: CodevisorServerServices,
  harness: Harness,
  cwd: string,
  requestedHarnessId: string | undefined,
  requestedConfigSelections: Readonly<Record<string, string>>
): Promise<HarnessCapability> => {
  const configSelections = requestedHarnessId === harness.id ? requestedConfigSelections : undefined
  let request: CapabilityRequest | undefined
  try {
    const account = await services.auth?.activeAccountContext(harness.id)
    request = { harnessId: harness.id, accountId: account?.id, cwd, configSelections }
    const metadata = await run(
      services.agents.inspectHarness(harness.id, cwd, account, configSelections)
    )
    const capability = capabilityFromMetadata(harness, metadata)
    capabilityMemory(services).remember(request, capability)
    return capability
  } catch (cause) {
    const remembered = rememberedAfterTimeout(services, request, cause)
    if (remembered === undefined) return failedHarnessCapability(harness, cause)
    return rememberedHarnessCapability(harness, cause, remembered)
  }
}

const rememberedAfterTimeout = (
  services: CodevisorServerServices,
  request: CapabilityRequest | undefined,
  cause: unknown
): HarnessCapability | undefined => {
  if (request === undefined || !inspectionTimedOut(cause)) return undefined
  return capabilityMemory(services).recall(request)
}

const discoverHarnessesWithAuthMode = async (
  services: CodevisorServerServices,
  authMode: "passive" | "force" | "settle" | "stored",
  harnessId?: string,
  includeLifecycle = false
): Promise<ReadonlyArray<Harness>> => {
  const discovered = await decorateHarnessSettings(
    services.db,
    await run(services.db.applyHarnessSettings(await run(services.agents.discoverHarnesses)))
  )
  const filtered =
    harnessId === undefined ? discovered : discovered.filter((harness) => harness.id === harnessId)
  let harnesses = filtered
  if (includeLifecycle && services.lifecycle !== undefined) {
    harnesses = await services.lifecycle.decorateHarnesses(filtered)
  }
  if (services.auth === undefined) return harnesses
  if (authMode === "stored") return services.auth.decorateHarnessesFromStoredState(harnesses)
  return services.auth.decorateHarnesses(harnesses, authMode)
}

export const discoverHarnesses = (
  services: CodevisorServerServices,
  forceAuth = false,
  harnessId?: string,
  includeLifecycle = false
): Promise<ReadonlyArray<Harness>> =>
  discoverHarnessesWithAuthMode(
    services,
    forceAuth ? "force" : "passive",
    harnessId,
    includeLifecycle
  )

export const discoverHarnessesFromStoredAuthState = (
  services: CodevisorServerServices
): Promise<ReadonlyArray<Harness>> =>
  discoverHarnessesWithAuthMode(services, "stored", undefined, true)

export const discoverSettledHarnesses = (
  services: CodevisorServerServices
): Promise<ReadonlyArray<Harness>> =>
  discoverHarnessesWithAuthMode(services, "settle", undefined, true)
