import type { Palette } from "../color/palette.js"
import { cyclops } from "../data.js"
import { f2 } from "../geometry/math.js"
import { arcD, glint, glintDot } from "../render/shine.js"
import { EYE_Y, eyeTheta, FACE_RADIUS } from "./eye-shape.js"
import type { FaceState } from "./face-state.js"

export interface Lens {
  readonly P: Palette
  readonly f: FaceState
  readonly id: string
  readonly x: number
  readonly y: number
  readonly k: number
  readonly turn: number
  readonly v: number
}

export type Axis = (u: number) => string

export type EyewearDrawing = (lens: Lens) => string

export const STRAP_REACH = FACE_RADIUS + 30

export function lensOf(P: Palette, f: FaceState, uid: string): Lens {
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

export const acrossOf =
  (lens: Lens): Axis =>
  (u) =>
    f2(lens.x + u * lens.k)

export const downOf =
  (y: number): Axis =>
  (u) =>
    f2(y + u)

export const goggleY = (lens: Lens): number =>
  EYE_Y + 6 * lens.v + cyclops.nudge[1] * Math.abs(lens.turn) + (lens.f.eyewearDy || 0) - 2

export function temples(lens: Lens, yy: number, l: number, r: number): string {
  return `<path d="M${f2(l)} ${f2(yy)}L${f2(250 - STRAP_REACH)} ${f2(yy)}M${f2(r)} ${f2(yy)}L${f2(250 + STRAP_REACH)} ${f2(yy)}" stroke="${lens.P.outline}" stroke-width="7" stroke-linecap="round" fill="none"/>`
}

export function glass(lens: Lens, rx: number, ry: number): string {
  const { x, y, id } = lens
  const glare =
    glint(arcD(x, y, rx * 0.74, ry * 0.74, -80, -26), 5) +
    glintDot(x + rx * 0.74 * Math.cos(-0.1), y + ry * 0.74 * Math.sin(-0.1), 2.4)
  return (
    `<clipPath id="${id}c"><ellipse cx="${f2(x)}" cy="${f2(y)}" rx="${f2(rx)}" ry="${f2(ry)}"/></clipPath>` +
    `<ellipse cx="${f2(x)}" cy="${f2(y)}" rx="${f2(rx)}" ry="${f2(ry)}" fill="#5B6B86" fill-opacity=".16"/><g class="glare" clip-path="url(#${id}c)">${glare}</g>`
  )
}

export function rim(lens: Lens, rx: number, ry: number, color: string, width: number): string {
  return `<ellipse cx="${f2(lens.x)}" cy="${f2(lens.y)}" rx="${f2(rx)}" ry="${f2(ry)}" fill="none" stroke="${color}" stroke-width="${width}"/>`
}

export function strapSpan(lens: Lens, side: number, inset: number): readonly [number, number] {
  const x0 = lens.x + side * inset * lens.k
  const x1 = 250 + side * STRAP_REACH
  return [Math.min(x0, x1), Math.max(x0, x1)]
}

export const band = ([a, b]: readonly [number, number], Y: Axis, half: number): string =>
  `M${f2(a)} ${Y(-half)}L${f2(b)} ${Y(-half)}L${f2(b)} ${Y(half)}L${f2(a)} ${Y(half)}Z`

export interface Box {
  readonly l: number
  readonly t: number
  readonly r: number
  readonly b: number
}

export function roundedBox(X: Axis, Y: Axis, { l, t, r, b }: Box, rad: number): string {
  return (
    `M${X(l + rad)} ${Y(t)}L${X(r - rad)} ${Y(t)}Q${X(r)} ${Y(t)} ${X(r)} ${Y(t + rad)}` +
    `L${X(r)} ${Y(b - rad)}Q${X(r)} ${Y(b)} ${X(r - rad)} ${Y(b)}` +
    `L${X(l + rad)} ${Y(b)}Q${X(l)} ${Y(b)} ${X(l)} ${Y(b - rad)}` +
    `L${X(l)} ${Y(t + rad)}Q${X(l)} ${Y(t)} ${X(l + rad)} ${Y(t)}Z`
  )
}

export const oval = (cx: number, cy: number, rx: number, ry: number, paint: string): string =>
  `<ellipse cx="${f2(cx)}" cy="${f2(cy)}" rx="${f2(rx)}" ry="${f2(ry)}" ${paint}/>`

export const outlined = (lens: Lens, width: number): string =>
  `stroke="${lens.P.outline}" stroke-width="${width}" stroke-linejoin="round"`

export const raisedBy =
  (Y: Axis, dy: number): Axis =>
  (u) =>
    Y(u + dy)

export const sideBands = (
  lens: Lens,
  Y: Axis,
  inset: number,
  half: number,
  paint: string
): string =>
  [-1, 1]
    .map((side) => `<path d="${band(strapSpan(lens, side, inset), Y, half)}" ${paint}/>`)
    .join("")

export function goggleShape(X: Axis, Y: Axis, w: number, h: number, notch: number): string {
  return (
    `M${X(-w + 18)} ${Y(-h)}Q${X(0)} ${Y(-h - 4)} ${X(w - 18)} ${Y(-h)}Q${X(w)} ${Y(-h)} ${X(w)} ${Y(-h + 18)}` +
    `L${X(w)} ${Y(h - 18)}Q${X(w)} ${Y(h)} ${X(w - 20)} ${Y(h)}L${X(17)} ${Y(h)}Q${X(0)} ${Y(h - notch)} ${X(-17)} ${Y(h)}` +
    `L${X(-w + 20)} ${Y(h)}Q${X(-w)} ${Y(h)} ${X(-w)} ${Y(h - 18)}L${X(-w)} ${Y(-h + 18)}Q${X(-w)} ${Y(-h)} ${X(-w + 18)} ${Y(-h)}Z`
  )
}
