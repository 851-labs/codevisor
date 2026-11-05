import { GOLD, hatTint, mix } from "../color/colors.js"
import { f2 } from "../geometry/math.js"
import { glintDot } from "../render/shine.js"
import { FACE_RADIUS } from "./eye-shape.js"
import {
  acrossOf,
  downOf,
  glass,
  outlined,
  raisedBy,
  rim,
  roundedBox,
  sideBands,
  temples,
  type Axis,
  type Lens
} from "./eyewear-lens.js"

const MIRROR: ReadonlyArray<readonly [string, number]> = [
  ["#ffffff", 0.55],
  ["#ffffff", 0.15],
  ["#000000", 0],
  ["#000000", 0.35],
  ["#ffffff", 0.3]
]

export function specs(lens: Lens): string {
  const rx = 40 * lens.k
  const ry = 40
  return (
    temples(lens, lens.y - 4, lens.x - rx, lens.x + rx) +
    glass(lens, rx, ry) +
    rim(lens, rx, ry, lens.P.outline, 9)
  )
}

export function monocle(lens: Lens): string {
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

export function shades(lens: Lens): string {
  const C = lens.f.eyewearColor || hatTint(lens.P.key)
  const X = acrossOf(lens)
  const Y = downOf(lens.y)
  const shield = shieldShape(X, Y)
  return (
    shadeArms(lens, Y, C) +
    `<linearGradient id="${lens.id}m" x1="0" y1="0" x2="1" y2="1">${mirrorStops(C)}</linearGradient>` +
    `<clipPath id="${lens.id}c"><path d="${shield}"/></clipPath>` +
    `<path d="${shield}" fill="url(#${lens.id}m)" fill-opacity=".94" ${outlined(lens, 6)}/>` +
    `<g class="glare" clip-path="url(#${lens.id}c)">` +
    `<path d="M${X(-30)} ${Y(-30)}L${X(-8)} ${Y(-30)}L${X(-44)} ${Y(40)}L${X(-66)} ${Y(40)}Z" fill="#fff" fill-opacity=".38"/>` +
    `<path d="M${X(2)} ${Y(-30)}L${X(10)} ${Y(-30)}L${X(-26)} ${Y(40)}L${X(-34)} ${Y(40)}Z" fill="#fff" fill-opacity=".3"/>` +
    glintDot(lens.x + 46 * lens.k, lens.y + 6, 2.6) +
    `</g>` +
    shadeBar(lens, X, Y, C)
  )
}

function shieldShape(X: Axis, Y: Axis): string {
  return (
    `M${X(-60)} ${Y(-30)}L${X(60)} ${Y(-30)}Q${X(70)} ${Y(-30)} ${X(69)} ${Y(-18)}L${X(66)} ${Y(8)}` +
    `Q${X(62)} ${Y(38)} ${X(34)} ${Y(38)}Q${X(16)} ${Y(38)} ${X(10)} ${Y(30)}Q${X(0)} ${Y(22)} ${X(-10)} ${Y(30)}` +
    `Q${X(-16)} ${Y(38)} ${X(-34)} ${Y(38)}Q${X(-62)} ${Y(38)} ${X(-66)} ${Y(8)}L${X(-69)} ${Y(-18)}Q${X(-70)} ${Y(-30)} ${X(-60)} ${Y(-30)}Z`
  )
}

function mirrorStops(C: string): string {
  const last = MIRROR.length - 1
  return MIRROR.map(
    ([toward, amount], i) =>
      `<stop offset="${f2(i / last)}" stop-color="${mix(C, toward, amount)}"/>`
  ).join("")
}

function shadeBar(lens: Lens, X: Axis, Y: Axis, C: string): string {
  const bar = roundedBox(X, Y, { l: -74, t: -44, r: 74, b: -20 }, 10)
  return (
    `<path d="${bar}" fill="${C}" ${outlined(lens, 7)}/>` +
    `<path d="M${X(-62)} ${Y(-37)}L${X(-30)} ${Y(-37)}" fill="none" stroke="${mix(C, "#ffffff", 0.55)}" stroke-width="4" stroke-linecap="round"/>`
  )
}

function shadeArms(lens: Lens, Y: Axis, C: string): string {
  const paint = `fill="${mix(C, "#000000", 0.25)}" ${outlined(lens, 7)} paint-order="stroke"`
  return sideBands(lens, raisedBy(Y, -31), 70, 6, paint)
}
