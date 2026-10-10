import { tmpdir } from "node:os"

import type { AgentSessionMetadata } from "@codevisor/agent-runtime"
import type { Harness, HarnessCapability } from "@codevisor/api"

import { decorateHarnessSettings } from "../infra/harness-preferences.js"
import type { CodevisorServerServices } from "../server-context.js"
import { existingDirectory, run } from "../server-http.js"
import { conflictFrom } from "./harness-errors.js"

export const discoverCapabilities = async (
  services: CodevisorServerServices,
  url: URL
): Promise<{ readonly harnesses: ReadonlyArray<HarnessCapability> }> => {
  const cwd = existingDirectory(url.searchParams.get("cwd")) ?? tmpdir()
  // Existing chats already know their harness. Filtering before auth
  // decoration and inspection is important: both stages can start real CLI
  // processes, so inspecting the whole catalog would put unrelated agents on
  // the resumed chat's critical path.
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

// Fleet-enabled harnesses blocked on sign-in ride along as capability
// entries with no options and NO inspection (inspection spawns the CLI).
// The composer renders them as "sign in required" rows; older clients
// already filter on harness.enabled and never see them.
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
    ...(metadata.skills === undefined ? {} : { skills: metadata.skills }),
    ...(metadata.unappliedConfigSelections === undefined
      ? {}
      : { unappliedConfigSelections: metadata.unappliedConfigSelections })
  }
}

const failedHarnessCapability = (harness: Harness, cause: unknown): HarnessCapability => {
  // The picker hides a harness with no model option, so a swallowed
  // failure here looks exactly like "not enabled" to the user. Say why.
  console.error(
    `[harnesses] inspecting ${harness.id} failed; it will be missing from the model picker: ${conflictFrom(cause).message}`
  )
  return {
    harness,
    configOptions: []
  }
}

const inspectHarnessCapability = async (
  services: CodevisorServerServices,
  harness: Harness,
  cwd: string,
  requestedHarnessId: string | undefined,
  requestedConfigSelections: Readonly<Record<string, string>>
): Promise<HarnessCapability> => {
  try {
    const account = await services.auth?.activeAccountContext(harness.id)
    const metadata = await run(
      services.agents.inspectHarness(
        harness.id,
        cwd,
        account,
        requestedHarnessId === harness.id ? requestedConfigSelections : undefined
      )
    )
    return capabilityFromMetadata(harness, metadata)
  } catch (cause) {
    return failedHarnessCapability(harness, cause)
  }
}

const discoverHarnessesWithAuthMode = async (
  services: CodevisorServerServices,
  authMode: "passive" | "force" | "stored",
  harnessId?: string,
  /// Lifecycle decoration (update knowledge, install methods) rides only on
  /// requests that render it — Settings, rescans, update checks. The plain
  /// list stays as light as possible for the composer's harness picker.
  includeLifecycle = false
): Promise<ReadonlyArray<Harness>> => {
  const discovered = await decorateHarnessSettings(
    services.db,
    await run(services.db.applyHarnessSettings(await run(services.agents.discoverHarnesses)))
  )
  const filtered =
    harnessId === undefined ? discovered : discovered.filter((harness) => harness.id === harnessId)
  const harnesses =
    includeLifecycle && services.lifecycle !== undefined
      ? await services.lifecycle.decorateHarnesses(filtered)
      : filtered
  return services.auth === undefined
    ? harnesses
    : authMode === "stored"
      ? services.auth.decorateHarnessesFromStoredState(harnesses)
      : services.auth.decorateHarnesses(harnesses, authMode === "force")
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

/// Readiness is derived in response to auth events, so it must only read the
/// state that caused the event. Starting another passive probe here turns one
/// probe failure into a feedback loop.
export const discoverHarnessesFromStoredAuthState = (
  services: CodevisorServerServices
): Promise<ReadonlyArray<Harness>> =>
  discoverHarnessesWithAuthMode(services, "stored", undefined, true)
