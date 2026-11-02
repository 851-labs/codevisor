import type { Body } from "../body/zones.js"
import { colorOf, CREAM, GOLD, wearTint, type Colorable } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import type { Point } from "../geometry/math.js"
import type { BotMascotPose } from "../pose.js"
import { garmentKit } from "./garment-kit.js"
import { dress, overalls, suit, type GarmentDrawing } from "./garments.js"

export type DrapeKind = "tie" | "tutu" | "dress" | "robe"

export interface Dangle {
  readonly anchor: Point
  readonly L: number
  readonly swing: number
  readonly lean?: number
  readonly neck?: boolean
  readonly waist?: boolean
  readonly role?: "drape"
  readonly w?: number
}

export interface Sleeve {
  readonly len: number
  readonly cuff?: string
}

export interface OutfitItem extends Colorable {
  readonly title: string
  readonly drape?: DrapeKind
  readonly neck?: boolean
  readonly waist?: boolean
  readonly sleeve?: Sleeve
  readonly dangles?: ReadonlyArray<Dangle>
  readonly draw?: GarmentDrawing
}

export const TIE_DROP = 16

export const outfitItems = {
  tie: {
    title: "Skinny tie",
    colors: "fabric",
    auto: true,
    drape: "tie",
    neck: true,
    dangles: [{ anchor: [250, 330 + TIE_DROP], L: 54, swing: 2.4, neck: true, role: "drape", w: 9 }]
  },
  tutu: {
    title: "Tutu",
    colors: "tulle",
    drape: "tutu",
    waist: true,
    dangles: [
      { anchor: [178, 322], L: 50, swing: 2.6, lean: -58, waist: true },
      { anchor: [322, 322], L: 50, swing: 2.6, lean: 58, waist: true }
    ]
  },
  dress: {
    title: "Dress",
    colors: "fabric",
    auto: true,
    drape: "dress",
    sleeve: { len: 0.3, cuff: CREAM },
    dangles: [
      { anchor: [194, 344], L: 62, swing: 2.2, lean: -50 },
      { anchor: [306, 344], L: 62, swing: 2.2, lean: 50 }
    ],
    draw: dress
  },
  robe: {
    title: "Wizard robe",
    colors: "wizard",
    drape: "robe",
    sleeve: { len: 0.58, cuff: GOLD },
    dangles: [
      { anchor: [178, 330], L: 80, swing: 1.9, lean: -22 },
      { anchor: [322, 330], L: 80, swing: 1.9, lean: 22 }
    ]
  },
  suit: { title: "Suit", colors: "suit", sleeve: { len: 0.6, cuff: "#F7F5F0" }, draw: suit },
  overalls: { title: "Overalls", draw: overalls }
} as const satisfies Readonly<Record<string, OutfitItem>>

export type OutfitKind = keyof typeof outfitItems

export const isOutfitKind = (kind: string | undefined): kind is OutfitKind =>
  kind !== undefined && Object.hasOwn(outfitItems, kind)

export const outfitItem = (kind: string | undefined): OutfitItem | undefined =>
  isOutfitKind(kind) ? outfitItems[kind] : undefined

const CLOTH_SHADE = "rgba(18,20,40,.2)"
export const SHADE_REGION = 'x="40" y="20" width="420" height="460"'

export function outfitColor(P: Palette, pose: BotMascotPose, item: OutfitItem): string {
  return colorOf(item, pose.wear?.outfitColor, wearTint(P.key).tee)
}

export function clothesSvg(body: Body, P: Palette, pose: BotMascotPose, uid: string): string {
  const item = outfitItem(pose.wear?.outfit)
  if (!item?.draw) return ""
  const kit = garmentKit(body, pose, uid)
  const [svg, region] = item.draw(P, wearTint(P.key), kit, outfitColor(P, pose, item), body)
  if (!region) return svg
  return (
    svg +
    `<clipPath id="${uid}cloth"><path d="${region}"/></clipPath><rect ${SHADE_REGION} fill="${CLOTH_SHADE}" mask="url(#${uid}m)" clip-path="url(#${uid}cloth)"/>`
  )
}

export function sleeveOf(P: Palette, pose: BotMascotPose): string {
  const w = pose.wear || {}
  const item = outfitItem(w.outfit)
  const op = w.clothesOp ?? 1
  if (!item?.sleeve || op <= 0.01) return ""
  return `${outfitColor(P, pose, item)}|${item.sleeve.len}|${item.sleeve.cuff || ""}|${op.toFixed(2)}`
}
