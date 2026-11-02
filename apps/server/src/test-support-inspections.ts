import { AgentRuntimeError } from "@codevisor/agent-runtime"
import type { AgentRuntimeService } from "@codevisor/agent-runtime"
import { Effect } from "effect"

export interface InspectionRecords {
  readonly inspections: Array<readonly [string, string]>
  readonly inspectionConfigs: Array<Readonly<Record<string, string>> | undefined>
  readonly timingOutInspections: Set<string>
}

export const stubInspectHarness =
  ({
    inspections,
    inspectionConfigs,
    timingOutInspections
  }: InspectionRecords): AgentRuntimeService["inspectHarness"] =>
  (harnessId, cwd, _account, configSelections) =>
    Effect.suspend(() => {
      if (!timingOutInspections.has(cwd)) return Effect.void
      return Effect.fail(
        new AgentRuntimeError({
          operation: "inspectHarness",
          message: "Harness inspection timed out after 15000ms",
          timedOut: true
        })
      )
    }).pipe(
      Effect.map(() => {
        inspections.push([harnessId, cwd])
        inspectionConfigs.push(configSelections)
        if (cwd.includes("capability-fail")) {
          throw new Error("capability probe failed")
        }
        if (cwd.includes("no-modes")) {
          return {
            sessionId: `inspect-${harnessId}`,
            configOptions: []
          }
        }
        if (cwd.includes("native-skills")) {
          return {
            sessionId: `inspect-${harnessId}`,
            configOptions: [],
            skills: {
              invocationPrefix: "/",
              skills: [{ invocation: "/review", name: "review", source: "builtin" as const }]
            }
          }
        }
        const unapplied = configSelections?.model === "gpt-gone"
        const model = unapplied ? "gpt-5" : (configSelections?.model ?? "gpt-5")
        return {
          ...(unapplied ? { unappliedConfigSelections: { model: "gpt-gone" } } : {}),
          sessionId: `inspect-${harnessId}`,
          supportsGoals: true,
          supportsSteering: true,
          modes: {
            currentModeId: "default",
            availableModes: [{ id: "default", name: "Default" }]
          },
          configOptions: [
            {
              id: "model",
              name: "Model",
              category: "model",
              currentValue: model,
              options: [{ value: "gpt-5", name: "GPT-5" }]
            },
            {
              id: "reasoning",
              name: "Reasoning",
              category: "thought_level",
              currentValue: model === "gpt-next" ? "high" : "medium",
              options:
                model === "gpt-next"
                  ? [{ value: "high", name: "High" }]
                  : [{ value: "medium", name: "Medium" }]
            }
          ]
        }
      })
    )
