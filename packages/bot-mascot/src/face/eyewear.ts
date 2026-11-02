import { GOLD, hatTint, mix, type Colorable } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import { cyclops } from "../data.js"
import { f2 } from "../geometry/math.js"
import { arcD, glint, glintDot } from "../render/shine.js"
import { EYE_Y, eyeTheta, FACE_RADIUS } from "./eye-shape.js"
import type { FaceState } from "./face-state.js"

export interface EyewearItem extends Colorable {
  readonly title: string
}

export const eyewearItems = {
  specs: { title: "Round specs" },
  monocle: { title: "Monocle" },
  goggles: { title: "Ski goggles", colors: "fabric", auto: true }
} as const satisfies Readonly<Record<string, EyewearItem>>

export type EyewearKind = keyof typeof eyewearItems

export const isEyewearKind = (kind: string | undefined): kind is EyewearKind =>
  kind !== undefined && Object.hasOwn(eyewearItems, kind)

export const eyewearItem = (kind: string | undefined): EyewearItem | undefined =>
  isEyewearKind(kind) ? eyewearItems[kind] : undefined

interface Lens {
  readonly P: Palette
  readonly f: FaceState
  readonly id: string
  readonly x: number
  readonly y: number
  readonly k: number
  readonly turn: number
  readonly v: number
}

const drawers: Readonly<Record<EyewearKind, (lens: Lens) => string>> = {
  specs: specs,
  monocle: monocle,
  goggles: goggles
}

export function eyewearSvg(P: Palette, f: FaceState, uid: string): string {
  const kind = f.eyewear
  const op = f.eyewearOp ?? 1
  if (!isEyewearKind(kind) || op <= 0.01) return ""
  const out = drawers[kind](lensOf(P, f, uid))
  return op < 0.999 ? `<g opacity="${f2(op)}">${out}</g>` : out
}

function lensOf(P: Palette, f: FaceState, uid: string): Lens {
  const turn = f.turn || 0
  const v = f.up || 0
  const th = eyeTheta(turn)
  return {
    P,
    f,
    id: `${uid}ew`,
    x: 250 + FACE_RADIUS * Math.sin(th) + cyclops.nudge[0] * turn,
    y: EYE_Y + 2 * v + cyclops.nudge[1] * Math.abs(turn) + (f.eyewearDy || 0),
    k: Math.cos(th),
    turn,
    v
  }
}

function temples(lens: Lens, yy: number, l: number, r: number): string {
  return `<path d="M${f2(l)} ${f2(yy)}L${f2(250 - FACE_RADIUS - 30)} ${f2(yy)}M${f2(r)} ${f2(yy)}L${f2(250 + FACE_RADIUS + 30)} ${f2(yy)}" stroke="${lens.P.outline}" stroke-width="7" stroke-linecap="round" fill="none"/>`
}

function glass(lens: Lens, rx: number, ry: number): string {
  const { x, y, id } = lens
  const glare =
    glint(arcD(x, y, rx * 0.74, ry * 0.74, -80, -26), 5) +
    glintDot(x + rx * 0.74 * Math.cos(-0.1), y + ry * 0.74 * Math.sin(-0.1), 2.4)
  return (
    `<clipPath id="${id}c"><ellipse cx="${f2(x)}" cy="${f2(y)}" rx="${f2(rx)}" ry="${f2(ry)}"/></clipPath>` +
    `<ellipse cx="${f2(x)}" cy="${f2(y)}" rx="${f2(rx)}" ry="${f2(ry)}" fill="#5B6B86" fill-opacity=".16"/><g class="glare" clip-path="url(#${id}c)">${glare}</g>`
  )
}

function rim(lens: Lens, rx: number, ry: number, color: string, width: number): string {
  return `<ellipse cx="${f2(lens.x)}" cy="${f2(lens.y)}" rx="${f2(rx)}" ry="${f2(ry)}" fill="none" stroke="${color}" stroke-width="${width}"/>`
}

function specs(lens: Lens): string {
  const rx = 40 * lens.k
  const ry = 40
  return (
    temples(lens, lens.y - 4, lens.x - rx, lens.x + rx) +
    glass(lens, rx, ry) +
    rim(lens, rx, ry, lens.P.outline, 9)
  )
}

function monocle(lens: Lens): string {
  const { x, y, P } = lens
  const rx = 37 * lens.k
  const ry = 37
  const a = (55 * Math.PI) / 180
  const sx = x + rx * Math.cos(a)
  const sy = y + ry * Math.sin(a)
  const ex = 250 + FACE_RADIUS + 24
  const ey = 342
  const chain = `M${f2(sx)} ${f2(sy)}Q${f2((sx + ex) / 2)} ${f2(ey + 30)} ${f2(ex)} ${f2(ey)}`
  return (
    `<path d="${chain}" fill="none" stroke="${P.outline}" stroke-width="7" stroke-linecap="round"/>` +
    `<path d="${chain}" fill="none" stroke="${GOLD}" stroke-width="3.5" stroke-linecap="round" stroke-dasharray="0.1 5.5"/>` +
    glass(lens, rx, ry) +
    rim(lens, rx, ry, P.outline, 12) +
    rim(lens, rx, ry, GOLD, 5.5)
  )
}

function goggles(lens: Lens): string {
  const { P, f, id, x, k } = lens
  const O = P.outline
  const C = f.eyewearColor || hatTint(P.key)
  const gy = EYE_Y + 6 * lens.v + cyclops.nudge[1] * Math.abs(lens.turn) + (f.eyewearDy || 0) - 2
  const X = (u: number): string => f2(x + u * k)
  const Y = (u: number): string => f2(gy + u)
  const frame = goggleShape(X, Y, 60, 40, 11)
  const lensD = goggleShape(X, Y, 49, 29.5, 10)
  return (
    goggleStrap(lens, Y, C, -1) +
    goggleStrap(lens, Y, C, 1) +
    `<linearGradient id="${id}m" x1="1" y1="0" x2="0" y2="1"><stop offset="0" stop-color="${mix(C, "#ffffff", 0.45)}" stop-opacity=".62"/><stop offset=".5" stop-color="${C}" stop-opacity=".66"/><stop offset="1" stop-color="${mix(C, "#000000", 0.35)}" stop-opacity=".76"/></linearGradient>` +
    `<path d="${frame}" fill="none" stroke="${O}" stroke-width="12" stroke-linejoin="round"/><path d="${frame}${lensD}" fill="${C}" fill-rule="evenodd"/>` +
    `<clipPath id="${id}c"><path d="${lensD}"/></clipPath><path d="${lensD}" fill="url(#${id}m)" stroke="${O}" stroke-width="4.5" stroke-linejoin="round"/>` +
    `<g class="glare" clip-path="url(#${id}c)">` +
    glint(`M${X(14)} ${Y(-21)}Q${X(37)} ${Y(-22)} ${X(40)} ${Y(-6)}`, 4.5) +
    `<circle cx="${X(40)}" cy="${Y(4)}" r="2.3" fill="#fff" fill-opacity=".92"/></g>`
  )
}

function goggleShape(
  X: (u: number) => string,
  Y: (u: number) => string,
  w: number,
  h: number,
  notch: number
): string {
  return (
    `M${X(-w + 18)} ${Y(-h)}Q${X(0)} ${Y(-h - 4)} ${X(w - 18)} ${Y(-h)}Q${X(w)} ${Y(-h)} ${X(w)} ${Y(-h + 18)}` +
    `L${X(w)} ${Y(h - 18)}Q${X(w)} ${Y(h)} ${X(w - 20)} ${Y(h)}L${X(17)} ${Y(h)}Q${X(0)} ${Y(h - notch)} ${X(-17)} ${Y(h)}` +
    `L${X(-w + 20)} ${Y(h)}Q${X(-w)} ${Y(h)} ${X(-w)} ${Y(h - 18)}L${X(-w)} ${Y(-h + 18)}Q${X(-w)} ${Y(-h)} ${X(-w + 18)} ${Y(-h)}Z`
  )
}

function goggleStrap(lens: Lens, Y: (u: number) => string, C: string, sg: number): string {
  const x0 = lens.x + sg * 54 * lens.k
  const x1 = 250 + sg * (FACE_RADIUS + 30)
  const a = Math.min(x0, x1)
  const b = Math.max(x0, x1)
  const dark = mix(C, "#000000", 0.3)
  const light = mix(C, "#ffffff", 0.45)
  return (
    `<path d="M${f2(a)} ${Y(-13)}L${f2(b)} ${Y(-13)}L${f2(b)} ${Y(13)}L${f2(a)} ${Y(13)}Z" fill="${dark}" stroke="${lens.P.outline}" stroke-width="9" stroke-linejoin="round" paint-order="stroke"/>` +
    `<path d="M${f2(a)} ${Y(-4.5)}L${f2(b)} ${Y(-4.5)}L${f2(b)} ${Y(4.5)}L${f2(a)} ${Y(4.5)}Z" fill="${light}"/>`
  )
}
