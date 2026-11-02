import { Cause, Effect } from "effect"

import { withSteeringSupport } from "./agent-runtime-core.js"
import type { HarnessDefinition } from "./harness-definition-types.js"
import { placeConfigValue } from "./model-selection.js"
import {
  runtimeError,
  type AgentProvider,
  type AgentRuntimeError,
  type AgentSessionMetadata,
  type CreatedAgentSession,
  type HarnessAccountContext
} from "./types.js"

export const INSPECTION_TIMEOUT_MS = 15_000

export interface HarnessInspection {
  readonly harnessId: string
  readonly definition: HarnessDefinition
  readonly provider: AgentProvider
  readonly cwd: string
  readonly account: HarnessAccountContext | undefined
  readonly configSelections: Readonly<Record<string, string>> | undefined
}

export const inspectHarnessSession = (
  inspection: HarnessInspection
): Effect.Effect<AgentSessionMetadata, AgentRuntimeError> =>
  Effect.gen(function* () {
    const created = yield* createInspectionSession(inspection).pipe(
      Effect.timeout(INSPECTION_TIMEOUT_MS),
      Effect.mapError((cause) =>
        runtimeError(
          "inspectHarness",
          cause._tag === "TimeoutError"
            ? new Error(`Harness inspection timed out after ${INSPECTION_TIMEOUT_MS}ms`)
            : cause
        )
      )
    )
    return yield* describeSession(inspection, created).pipe(
      Effect.ensuring(Effect.sync(() => closeInBackground(created)))
    )
  })

const createInspectionSession = ({
  definition,
  provider,
  cwd,
  account,
  configSelections
}: HarnessInspection): Effect.Effect<CreatedAgentSession, AgentRuntimeError> =>
  provider.createSession(
    definition,
    cwd,
    /* v8 ignore next */
    () => Promise.resolve(),
    account,
    undefined,
    {
      modelListTimeoutMs: Math.max(3_000, INSPECTION_TIMEOUT_MS - 3_000),
      skillListTimeoutMs: 2_000,
      ...(configSelections === undefined ? {} : { configSelections })
    }
  )

const closeInBackground = (created: CreatedAgentSession): void => {
  void Effect.runPromise(created.handle.close).catch(() => undefined)
}

const describeSession = (
  { harnessId, provider, configSelections }: HarnessInspection,
  created: CreatedAgentSession
): Effect.Effect<AgentSessionMetadata> =>
  Effect.gen(function* () {
    let configOptions = created.metadata.configOptions
    const unapplied: Record<string, string> = {}
    for (const [configId, value] of orderedSelections(configSelections)) {
      const option = configOptions.find((candidate) => candidate.id === configId)
      const target =
        option === undefined
          ? undefined
          : placeConfigValue(option, value, provider.reconcileConfigValue)
      if (target === undefined) {
        unapplied[configId] = value
        continue
      }
      if (option?.currentValue === target) continue
      configOptions = yield* created.handle.setConfigOption(configId, target).pipe(
        Effect.catchCause((cause) => {
          console.error(
            `[agent-runtime] inspectHarness(${harnessId}) could not apply ${configId}=${target}: ${Cause.pretty(cause)}`
          )
          unapplied[configId] = value
          return Effect.succeed(configOptions)
        })
      )
    }
    return {
      ...withSteeringSupport(created.metadata, created.handle),
      configOptions,
      ...(Object.keys(unapplied).length === 0 ? {} : { unappliedConfigSelections: unapplied })
    }
  })

const orderedSelections = (
  configSelections: Readonly<Record<string, string>> | undefined
): ReadonlyArray<readonly [string, string]> =>
  Object.entries(configSelections ?? {}).toSorted(([left], [right]) => {
    if (left === "model") return -1
    if (right === "model") return 1
    return left.localeCompare(right)
  })
