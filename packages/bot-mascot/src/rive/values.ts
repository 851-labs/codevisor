import { resolveConfig, type BotMascotConfig } from "../config.js"
import table from "../data/rive-colors.json" with { type: "json" }

export type RiveColorTable = Readonly<Record<string, Readonly<Record<string, ChoiceColors>>>>
export type RiveValue = string | number
export type RiveValues = Readonly<Record<string, RiveValue>>

type ChoiceColors = Readonly<Record<string, Readonly<Record<string, ReadonlyArray<string>>>>>

interface Slot {
  readonly prefix: string
  readonly category: string
  readonly item: string
  readonly choice: string
}

export const riveColorTable: RiveColorTable = table

export const RIVE_ARTBOARD = "Bot Mascot"
export const RIVE_STATE_MACHINE = "Bot Mascot"

export function riveValues(
  config: BotMascotConfig = {},
  colors: RiveColorTable = riveColorTable
): RiveValues {
  const look = resolveConfig(config)
  const out: Record<string, RiveValue> = {
    hat: look.hat,
    outfit: look.outfit,
    "face/eyewear": look.eyewear,
    "face/lashesOn": look.makeup.lashes ? 1 : 0,
    "face/blushOn": look.makeup.blush ? 1 : 0,
    "face/frecklesOn": look.makeup.freckles ? 1 : 0
  }
  for (const slot of slotsOf(look)) addSlots(out, slot, colors, look.color)
  return out
}

export const isRiveColor = (value: RiveValue): value is string =>
  typeof value === "string" && /^[0-9A-F]{8}$/.test(value)

function slotsOf(look: ReturnType<typeof resolveConfig>): ReadonlyArray<Slot> {
  const slots: Array<Slot> = [
    { prefix: "body", category: "body", item: "body", choice: "auto" },
    { prefix: "face/face", category: "face", item: "face", choice: "auto" },
    { prefix: "face/blush", category: "blush", item: "blush", choice: look.blushColor },
    { prefix: "face/freckles", category: "freckles", item: "freckles", choice: "auto" },
    { prefix: "phone", category: "phone", item: "phone", choice: "auto" },
    { prefix: "clipboard", category: "clipboard", item: "clipboard", choice: "auto" }
  ]
  if (look.hat !== "none")
    slots.push({ prefix: "hat", category: "hat", item: look.hat, choice: look.hatColor })
  if (look.outfit !== "none")
    slots.push({
      prefix: "outfit",
      category: "outfit",
      item: look.outfit,
      choice: look.outfitColor
    })
  if (look.eyewear !== "none")
    slots.push({
      prefix: "face/eyewear",
      category: "eyewear",
      item: look.eyewear,
      choice: look.eyewearColor
    })
  return slots
}

function addSlots(
  out: Record<string, RiveValue>,
  slot: Slot,
  colors: RiveColorTable,
  color: string
): void {
  const byChoice = colors[slot.category]?.[slot.item]
  if (!byChoice) return
  const values = (byChoice[slot.choice] ?? byChoice.auto)?.[color] ?? []
  values.forEach((value, k) => (out[`${slot.prefix}${k}`] = value))
}
