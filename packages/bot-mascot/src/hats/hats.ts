import { headTf } from "../body/rig.js"
import type { Body } from "../body/zones.js"
import { colorOf, hatTint, type Colorable } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import { fa } from "../geometry/math.js"
import type { BotMascotPose, HatPose } from "../pose.js"
import {
  beret,
  bucketHat,
  chefHat,
  conicalHat,
  cowboyHat,
  floppyHat,
  sailorHat,
  strawHat
} from "./brim-hats.js"
import { crown, hardHat, propellerCap, pumpkin, rubberDuck, topHat } from "./hard-hats.js"
import { antenna, beanie, partyHat, wizardHat } from "./soft-hats.js"

export type HatDrawing = (P: Palette, A: string, id: string, hat: HatPose) => string

export interface HatItem extends Colorable {
  readonly title: string
  readonly soft?: boolean
  readonly draw: HatDrawing
}

export const hatItems = {
  beanie: { title: "Beanie", colors: "fabric", auto: true, draw: beanie },
  party: { title: "Party hat", colors: "fabric", auto: true, draw: partyHat },
  propeller: { title: "Propeller cap", draw: propellerCap },
  crown: { title: "Crown", draw: crown },
  tophat: { title: "Top hat", colors: "fabric", auto: true, draw: topHat },
  pumpkin: { title: "Jack-o'-lantern", draw: pumpkin },
  antennae: { title: "Antenna", soft: true, draw: antenna },
  wizard: { title: "Wizard hat", colors: "wizard", draw: wizardHat },
  duck: { title: "Rubber duck", draw: rubberDuck },
  hardhat: { title: "Hard hat", draw: hardHat },
  chef: { title: "Chef hat", draw: chefHat },
  sailor: { title: "Sailor hat", draw: sailorHat },
  cowboy: { title: "Cowboy hat", draw: cowboyHat },
  conical: { title: "Conical hat", draw: conicalHat },
  straw: { title: "Straw hat", draw: strawHat },
  floppy: { title: "Floppy hat", colors: "fabric", auto: true, draw: floppyHat },
  beret: { title: "Beret", colors: "fabric", auto: true, draw: beret },
  bucket: { title: "Bucket hat", colors: "fabric", auto: true, draw: bucketHat }
} as const satisfies Readonly<Record<string, HatItem>>

export type HatKind = keyof typeof hatItems

export const isHatKind = (kind: string | undefined): kind is HatKind =>
  kind !== undefined && Object.hasOwn(hatItems, kind)

export const hatItem = (kind: string | undefined): HatItem | undefined =>
  isHatKind(kind) ? hatItems[kind] : undefined

const HAT_TOP = 186

export function hatSvg(P: Palette, hat: HatPose | undefined, uid: string): string {
  const item = hatItem(hat?.kind)
  if (!item || !hat) return ""
  return item.draw(P, colorOf(item, hat.color, hatTint(P.key)), `${uid}h`, hat)
}

export function hatTf(body: Body, pose: BotMascotPose, sx: number, sy: number): string {
  const h: Partial<HatPose> = pose.hat || {}
  const head = headTf(body, pose, HAT_TOP)
  if (hatItem(h.kind)?.soft) return `${head} translate(250 186)`
  return `${head} translate(250 186) scale(${fa(sx ** -0.6)} ${fa(sy ** -0.6)}) translate(0 ${fa(h.dy || 0)}) rotate(${fa(h.rot || 0)})`.trim()
}
