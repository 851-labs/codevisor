import { choiceField, stringValue, type SandboxField, type SandboxFieldValues } from "./fields.js"
import type { CreateSpec } from "./provider.js"

export const PAUSE_AFTER_KEY = "pauseAfter"
export const NEVER_PAUSE = "never"

export interface PausedMachine {
  readonly providerMachineId: string
  readonly snapshot?: string
}

export interface WokenMachine {
  readonly providerMachineId: string
  readonly expiresAt?: string
}

export interface SandboxPausing {
  readonly pause: (providerMachineId: string) => Promise<PausedMachine>
  readonly wake: (
    paused: PausedMachine,
    spec: CreateSpec,
    options: SandboxFieldValues
  ) => Promise<WokenMachine>
  readonly keepAlive?: (providerMachineId: string, untilMs: number) => Promise<string | undefined>
}

const defaultPauseAfter = "30"
const pauseAfterChoices = [
  { value: "15", label: "15 min" },
  { value: "30", label: "30 min" },
  { value: "60", label: "1 hr" },
  { value: "240", label: "4 hr" }
]
const neverChoice = { value: NEVER_PAUSE, label: "Never" }
const millisecondsPerMinute = 60 * 1000

export const pauseAfterField = (offers: { readonly never: boolean }): SandboxField =>
  choiceField(
    PAUSE_AFTER_KEY,
    "Pause after",
    offers.never ? [...pauseAfterChoices, neverChoice] : pauseAfterChoices,
    {
      default: defaultPauseAfter,
      description: "How long a sandbox stays alive without a chat running."
    }
  )

export const pauseAfterMs = (options: SandboxFieldValues): number | undefined => {
  const value = stringValue(options, PAUSE_AFTER_KEY)
  if (value === NEVER_PAUSE || value === "") return undefined

  return Number(value) * millisecondsPerMinute
}
