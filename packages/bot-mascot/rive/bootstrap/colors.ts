import {
  botMascotEyewear,
  botMascotHats,
  botMascotMakeup,
  botMascotOutfits,
  type BotMascotColor,
  type BotMascotConfig,
  type SwatchChoice
} from "../../src/index.js"
import { paintsOf, type Item, type Stop } from "./collect.js"
import { COLORS, type PartOf, mainBodyPart, noMakeup, part, render } from "./parts.js"
import { clipboardItems, phoneItems } from "./props.js"
import { sleevePart } from "./sleeves.js"

export interface Slots {
  readonly paintSlot: Array<number | null>
  readonly count: number
  readonly values: (look: number) => string[]
}

export const lerpArgb = (a: string, b: string, u: number): string =>
  [0, 2, 4, 6]
    .map((i) =>
      Math.round(parseInt(a.slice(i, i + 2), 16) * (1 - u) + parseInt(b.slice(i, i + 2), 16) * u)
        .toString(16)
        .padStart(2, "0")
        .toUpperCase()
    )
    .join("")

export function sampleStops(stops: Stop[], offsets: number[]): Stop[] {
  return offsets.map((o) => {
    const i = stops.findIndex((s) => s.offset >= o - 1e-9)
    if (i <= 0) return { offset: o, color: (i === 0 ? stops[0] : stops[stops.length - 1]).color }
    const a = stops[i - 1]
    const b = stops[i]
    const u = b.offset - a.offset < 1e-9 ? 1 : (o - a.offset) / (b.offset - a.offset)
    return { offset: o, color: lerpArgb(a.color, b.color, u) }
  })
}

export type StopPlan = Map<string, number[]>
export function planStops(lists: Item[][]): StopPlan {
  const plan: StopPlan = new Map()
  const note = (key: string, p: Item["fill"]) => {
    if (!p || p.kind === "solid") return
    const set = new Set([
      ...(plan.get(key) ?? []),
      ...p.stops.map((s) => Math.round(s.offset * 1e4) / 1e4)
    ])
    plan.set(
      key,
      [...set].toSorted((x, y) => x - y)
    )
  }
  for (const items of lists)
    items.forEach((it, i) => (note(`${i}f`, it.fill), note(`${i}s`, it.stroke?.paint ?? null)))
  return plan
}

export function applyStops(items: Item[], plan: StopPlan): Item[] {
  const fix = (key: string, p: Item["fill"]): Item["fill"] =>
    !p || p.kind === "solid" || !plan.has(key)
      ? p
      : { ...p, stops: sampleStops(p.stops, plan.get(key)!) }
  return items.map((it, i) => ({
    ...it,
    fill: fix(`${i}f`, it.fill),
    stroke: it.stroke ? { ...it.stroke, paint: fix(`${i}s`, it.stroke.paint)! } : null
  }))
}

export const stopPlans = new Map<string, StopPlan>()
export const plannedItems = (key: string, items: Item[]): Item[] =>
  applyStops(items, stopPlans.get(key) ?? new Map())

export const planned =
  (key: string, of: PartOf): PartOf =>
  (root) =>
    applyStops(of(root), stopPlans.get(key) ?? new Map())

export function slotsFor(
  looks: BotMascotConfig[],
  itemsFor: (config: BotMascotConfig) => Item[],
  key: string
): Slots {
  const raw = looks.map(itemsFor)
  const plan = planStops(raw)
  stopPlans.set(key, plan)
  const paints = raw.map((items) => paintsOf(applyStops(items, plan)))
  const n = paints[0].length
  for (const p of paints)
    if (p.length !== n) throw new Error(`paint count differs: ${n} vs ${p.length}`)
  const tuples: string[] = []
  const paintSlot = Array.from({ length: n }, (_, j) => {
    const tuple = paints.map((p) => p[j]).join(",")
    if (paints.every((p) => p[j] === paints[0][j])) return null
    let k = tuples.indexOf(tuple)
    if (k < 0) k = tuples.push(tuple) - 1
    return k
  })
  return {
    paintSlot,
    count: tuples.length,
    values: (look) =>
      tuples.map((_, k) => {
        const j = paintSlot.indexOf(k)
        return paints[look][j]
      })
  }
}

export const choicesOf = (o: {
  swatches: ReadonlyArray<SwatchChoice>
  hasAuto: boolean
}): SwatchChoice[] => ["auto", ...o.swatches]

export interface CategoryItem {
  readonly id: string
  readonly choiceKey?: keyof BotMascotConfig
  readonly choices: SwatchChoice[]
  readonly config: (choice: SwatchChoice) => BotMascotConfig
  readonly of: PartOf
  readonly itemsFor?: (config: BotMascotConfig) => Item[]
}

export interface Category {
  readonly name: string
  readonly items: CategoryItem[]
}

export const looksOf = (
  item: CategoryItem
): Array<{ color: BotMascotColor; choice: string; config: BotMascotConfig }> =>
  item.choices.flatMap((choice) =>
    COLORS.map((color) => ({ color, choice, config: { ...item.config(choice), color } }))
  )

export const blushChoices = choicesOf(botMascotMakeup.find((m) => m.id === "blush")!)

export const categories: Category[] = [
  {
    name: "body",
    items: [
      { id: "body", choices: ["auto"], config: () => ({ makeup: noMakeup }), of: mainBodyPart }
    ]
  },
  {
    name: "hat",
    items: botMascotHats.map((h) => ({
      id: h.id,
      choices: choicesOf(h),
      config: (c) => ({ hat: h.id, hatColor: c, makeup: noMakeup }),
      of: part("hat")
    }))
  },
  {
    name: "outfit",
    items: botMascotOutfits.map((o) => ({
      id: o.id,
      choices: choicesOf(o),
      config: (c) => ({ outfit: o.id, outfitColor: c, makeup: noMakeup }),
      of: (root) => [...part("wear")(root), ...part("drape")(root), ...sleevePart(root)]
    }))
  },
  {
    name: "face",
    items: [
      {
        id: "face",
        choices: ["auto"],
        config: () => ({ makeup: { ...noMakeup, lashes: true } }),
        of: part("face", true)
      }
    ]
  },
  {
    name: "blush",
    items: [
      {
        id: "blush",
        choices: blushChoices,
        config: (c) => ({ makeup: { ...noMakeup, blush: true }, blushColor: c }),
        of: part("makeup", true)
      }
    ]
  },
  {
    name: "freckles",
    items: [
      {
        id: "freckles",
        choices: ["auto"],
        config: () => ({ makeup: { ...noMakeup, freckles: true } }),
        of: part("makeup", true)
      }
    ]
  },
  {
    name: "eyewear",
    items: botMascotEyewear.map((e) => ({
      id: e.id,
      choices: choicesOf(e),
      config: (c) => ({ eyewear: e.id, eyewearColor: c, makeup: noMakeup }),
      of: part("eyewear", true)
    }))
  },
  {
    name: "phone",
    items: [
      {
        id: "phone",
        choices: ["auto"],
        config: () => ({ makeup: noMakeup }),
        of: () => [],
        itemsFor: phoneItems
      }
    ]
  },
  {
    name: "clipboard",
    items: [
      {
        id: "clipboard",
        choices: ["auto"],
        config: () => ({ makeup: noMakeup }),
        of: () => [],
        itemsFor: clipboardItems
      }
    ]
  }
]

export const slotTables = new Map<string, Slots>()
export const slotCounts = new Map<string, number>()
export const colorTable: Record<
  string,
  Record<string, Record<string, Record<string, string[]>>>
> = {}
for (const cat of categories) {
  colorTable[cat.name] = {}
  for (const item of cat.items) {
    const looks = looksOf(item)
    const slots = slotsFor(
      looks.map((l) => l.config),
      item.itemsFor ?? ((config) => item.of(render(config))),
      `${cat.name}/${item.id}`
    )
    slotTables.set(`${cat.name}/${item.id}`, slots)
    slotCounts.set(cat.name, Math.max(slotCounts.get(cat.name) ?? 0, slots.count))
    const table: Record<string, Record<string, string[]>> = {}
    looks.forEach((l, i) => {
      table[l.choice] ??= {}
      table[l.choice][l.color] = slots.values(i)
    })
    colorTable[cat.name][item.id] = table
  }
}
