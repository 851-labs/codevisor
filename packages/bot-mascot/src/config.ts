import { officialBodyZones } from "./body/zones.js"
import { botMascotColorIds, defaultBotMascotColor, type BotMascotColor } from "./color/palette.js"
import type { BotMascotMood } from "./moods/moods.js"
import {
  botMascotEyewear,
  botMascotHats,
  botMascotOutfits,
  swatchesFor,
  type BotMascotEyewear,
  type BotMascotHat,
  type BotMascotOutfit,
  type BotMascotSwatch
} from "./options.js"
import type { BotMascotPose, HatPose, MakeupChoice, WearPose } from "./pose.js"

export type SwatchChoice = BotMascotSwatch | "auto"

export interface BotMascotConfig {
  readonly color?: BotMascotColor
  readonly hat?: BotMascotHat | "none"
  readonly hatColor?: SwatchChoice
  readonly eyewear?: BotMascotEyewear | "none"
  readonly eyewearColor?: SwatchChoice
  readonly outfit?: BotMascotOutfit | "none"
  readonly outfitColor?: SwatchChoice
  readonly makeup?: MakeupChoice
  readonly blushColor?: SwatchChoice
  readonly mood?: BotMascotMood
}

export type ResolvedBotMascotConfig = Required<BotMascotConfig> & {
  readonly makeup: Required<MakeupChoice>
}

export const defaultBotMascotConfig: ResolvedBotMascotConfig = {
  color: defaultBotMascotColor,
  mood: "idle",
  hat: "none",
  hatColor: "auto",
  eyewear: "none",
  eyewearColor: "auto",
  outfit: "none",
  outfitColor: "auto",
  makeup: { blush: true, freckles: false, lashes: false },
  blushColor: "auto"
}

export function resolveConfig(config: BotMascotConfig = {}): ResolvedBotMascotConfig {
  return {
    ...defaultBotMascotConfig,
    ...config,
    makeup: { ...defaultBotMascotConfig.makeup, ...config.makeup }
  }
}

export function wearOf(c: ResolvedBotMascotConfig): WearPose {
  return {
    eyewear: c.eyewear,
    eyewearColor: c.eyewearColor,
    outfit: c.outfit,
    outfitColor: c.outfitColor,
    makeup: c.makeup,
    blushColor: c.blushColor
  }
}

export function hatOf(c: ResolvedBotMascotConfig): HatPose | undefined {
  return c.hat === "none" ? undefined : { kind: c.hat, color: c.hatColor }
}

export function dressed(c: ResolvedBotMascotConfig): (pose: BotMascotPose) => BotMascotPose {
  const hat = hatOf(c)
  const wear = wearOf(c)
  return (p) => ({ ...p, ...(hat ? { hat } : {}), wear })
}

const VIEW = [65, 70, 370, 370] as const
const VIEW_WITH_HAT = [47, 32, 406, 406] as const

export function portraitViewBox(hat: BotMascotConfig["hat"]): string {
  const v = hat && hat !== "none" ? VIEW_WITH_HAT : VIEW
  const dy = officialBodyZones.dy * 0.9
  const tall = dy ? [v[0] - dy / 2, v[1] - dy, v[2] + dy, v[3] + dy] : v
  return tall.map((n) => n.toFixed(3)).join(" ")
}

export type Random = () => number

export function randomBotMascotConfig(
  random: Random = Math.random,
  from: BotMascotConfig = {}
): ResolvedBotMascotConfig {
  const current = resolveConfig(from)
  const pick = <T>(a: ReadonlyArray<T>): T => a[Math.floor(random() * a.length)]!
  const maybe = <T extends string>(pNone: number, ids: ReadonlyArray<T>): T | "none" =>
    random() < pNone ? "none" : pick(ids)
  const colorFor = (
    item:
      | { readonly swatches: ReadonlyArray<BotMascotSwatch>; readonly hasAuto: boolean }
      | undefined
  ): SwatchChoice =>
    !item?.swatches.length || (item.hasAuto && random() < 0.3) ? "auto" : pick(item.swatches)
  const color = pick(botMascotColorIds.filter((k) => k !== current.color))
  const hat = maybe(
    0.3,
    botMascotHats.map((o) => o.id)
  )
  const eyewear = maybe(
    0.45,
    botMascotEyewear.map((o) => o.id)
  )
  const outfit = maybe(
    0.35,
    botMascotOutfits.map((o) => o.id)
  )
  return {
    ...current,
    color,
    hat,
    eyewear,
    outfit,
    hatColor: colorFor(botMascotHats.find((o) => o.id === hat)),
    eyewearColor: colorFor(botMascotEyewear.find((o) => o.id === eyewear)),
    outfitColor: colorFor(botMascotOutfits.find((o) => o.id === outfit)),
    makeup: { blush: random() < 0.8, freckles: random() < 0.3, lashes: random() < 0.35 },
    blushColor: random() < 0.5 ? "auto" : pick(swatchesFor("blush"))
  }
}
