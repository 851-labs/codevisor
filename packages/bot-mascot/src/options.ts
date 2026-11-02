import { hatTint, namedColors, swatches, type NamedColor, type SwatchSet } from "./color/colors.js"
import { botMascotColorIds, palette, rawPalette, type BotMascotColor } from "./color/palette.js"
import { eyewearItems, type EyewearKind } from "./face/eyewear.js"
import { makeupItems } from "./face/makeup.js"
import { hatItems, type HatKind } from "./hats/hats.js"
import { botMascotMoods, type BotMascotMood } from "./moods/moods.js"
import { outfitItems, type OutfitKind } from "./outfits/outfits.js"

export type BotMascotHat = HatKind
export type BotMascotEyewear = EyewearKind
export type BotMascotOutfit = OutfitKind
export type BotMascotMakeup = keyof typeof makeupItems
export type BotMascotSwatch = NamedColor
export type { BotMascotColor, BotMascotMood }

export interface ColorOption {
  readonly id: BotMascotColor
  readonly title: string
  readonly note: string
  readonly gradient: ReadonlyArray<readonly [number, string]>
  readonly outline: string
  readonly accent: string
}

export interface ItemOption<Id extends string> {
  readonly id: Id
  readonly title: string
  readonly swatches: ReadonlyArray<BotMascotSwatch>
  readonly hasAuto: boolean
}

export interface MoodOption {
  readonly id: BotMascotMood
  readonly title: string
  readonly loop: number | null
  readonly still: number
}

export interface SwatchOption {
  readonly id: BotMascotSwatch
  readonly hex: string
}

export const botMascotColors: ReadonlyArray<ColorOption> = botMascotColorIds.map((id) => {
  const P = palette(id)
  return {
    id,
    title: P.title,
    note: rawPalette(id).note,
    gradient: P.body,
    outline: P.outline,
    accent: hatTint(id)
  }
})

export const botMascotHats = itemOptions(hatItems)
export const botMascotEyewear = itemOptions(eyewearItems)
export const botMascotOutfits = itemOptions(outfitItems)
export const botMascotMakeup = itemOptions(makeupItems)

export const botMascotMoodOptions: ReadonlyArray<MoodOption> = keysOf(botMascotMoods).map((id) => {
  const m = botMascotMoods[id]
  return { id, title: m.title, loop: m.loop, still: m.still }
})

export const botMascotSwatches: ReadonlyArray<SwatchOption> = keysOf(namedColors).map((id) => ({
  id,
  hex: namedColors[id]
}))

export function swatchesFor(set: SwatchSet | undefined): ReadonlyArray<BotMascotSwatch> {
  return set ? swatches[set].map(([id]) => id) : []
}

function itemOptions<Id extends string>(
  items: Readonly<
    Record<Id, { readonly title: string; readonly colors?: SwatchSet; readonly auto?: boolean }>
  >
): ReadonlyArray<ItemOption<Id>> {
  return keysOf(items).map((id) => {
    const item = items[id]
    return { id, title: item.title, swatches: swatchesFor(item.colors), hasAuto: !!item.auto }
  })
}

function keysOf<T extends object>(o: T): Array<keyof T & string> {
  return Object.keys(o).filter((k): k is keyof T & string => Object.hasOwn(o, k))
}
