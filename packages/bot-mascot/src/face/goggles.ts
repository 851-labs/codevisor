import { hatTint, mix } from "../color/colors.js"
import { f2 } from "../geometry/math.js"
import { arcD, glint, glintDot } from "../render/shine.js"
import {
  acrossOf,
  band,
  downOf,
  goggleShape,
  goggleY,
  outlined,
  oval,
  roundedBox,
  sideBands,
  strapSpan,
  type Axis,
  type Lens
} from "./eyewear-lens.js"

const LEATHER = "#7A4B2B"
const STITCH = "#E9CB9C"
const STEEL = ["#E3E7EC", "#8C94A1"] as const
const WELD_GLASS = "#2B5C41"
const WEBBING = "#5B6440"
const HOUSING = "#353A2E"
const TUBE = "#66704C"
const PHOSPHOR = ["#E4FFC2", "#7EE36B", "#1F7A35"] as const
const TUBE_DEPTH = 9
const WELD_TINT = ".7"

export function goggles(lens: Lens): string {
  const { P, f, id, x, k } = lens
  const O = P.outline
  const C = f.eyewearColor || hatTint(P.key)
  const gy = goggleY(lens)
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

export function welder(lens: Lens): string {
  const { id, k } = lens
  const cy = goggleY(lens)
  const Y = downOf(cy)
  const cx = lens.x
  return (
    sideBands(lens, Y, 40, 12, `fill="${LEATHER}" ${outlined(lens, 9)} paint-order="stroke"`) +
    stitching(lens, Y) +
    `<linearGradient id="${id}s" x1="0" y1="0" x2="1" y2="1"><stop offset="0" stop-color="${STEEL[0]}"/><stop offset="1" stop-color="${STEEL[1]}"/></linearGradient>` +
    oval(cx, cy, 44 * k, 44, `fill="url(#${id}s)" ${outlined(lens, 9)}`) +
    oval(
      cx,
      cy,
      38.5 * k,
      38.5,
      `fill="none" stroke="#5D6470" stroke-width="4" stroke-dasharray="1.5 4.5"`
    ) +
    oval(cx, cy, 33 * k, 33, `fill="#3B4049" ${outlined(lens, 4)}`) +
    `<clipPath id="${id}c"><ellipse cx="${f2(cx)}" cy="${f2(cy)}" rx="${f2(28 * k)}" ry="28"/></clipPath>` +
    oval(cx, cy, 28 * k, 28, `fill="${WELD_GLASS}" fill-opacity="${WELD_TINT}"`) +
    `<g class="glare" clip-path="url(#${id}c)">` +
    glint(arcD(cx, cy, 20 * k, 20, -80, -26), 4.5) +
    glintDot(cx + 20 * k * Math.cos(-0.1), cy + 20 * Math.sin(-0.1), 2.2) +
    `</g>`
  )
}

export function nightVision(lens: Lens): string {
  const { id, k } = lens
  const cy = goggleY(lens)
  const X = acrossOf(lens)
  const Y = downOf(cy)
  const tx = lens.x + TUBE_DEPTH * lens.turn
  return (
    sideBands(lens, Y, 30, 11, `fill="${WEBBING}" ${outlined(lens, 9)} paint-order="stroke"`) +
    `<path d="${roundedBox(X, Y, { l: -11, t: -150, r: 11, b: -20 }, 4)}" fill="${WEBBING}" ${outlined(lens, 8)}/>` +
    `<path d="${roundedBox(X, Y, { l: 40, t: -10, r: 56, b: 10 }, 4)}" fill="${HOUSING}" ${outlined(lens, 5)}/>` +
    oval(lens.x, cy, 47 * k, 47, `fill="${TUBE}" ${outlined(lens, 8)}`) +
    oval(tx, cy, 34 * k, 34, `fill="${HOUSING}" ${outlined(lens, 6)}`) +
    oval(tx, cy, 28 * k, 28, `fill="#1C1F19"`) +
    `<radialGradient id="${id}g" cx=".42" cy=".4" r=".62"><stop offset="0" stop-color="${PHOSPHOR[0]}"/><stop offset=".5" stop-color="${PHOSPHOR[1]}"/><stop offset="1" stop-color="${PHOSPHOR[2]}"/></radialGradient>` +
    `<clipPath id="${id}c"><ellipse cx="${f2(tx)}" cy="${f2(cy)}" rx="${f2(24 * k)}" ry="24"/></clipPath>` +
    oval(tx, cy, 24 * k, 24, `fill="url(#${id}g)" fill-opacity=".9" ${outlined(lens, 4)}`) +
    `<g class="glare" clip-path="url(#${id}c)">` +
    glint(arcD(tx, cy, 17 * k, 17, -80, -26), 4) +
    glintDot(tx + 17 * k * Math.cos(-0.1), cy + 17 * Math.sin(-0.1), 2) +
    `</g>`
  )
}

function goggleStrap(lens: Lens, Y: Axis, C: string, side: number): string {
  const span = strapSpan(lens, side, 54)
  return (
    `<path d="${band(span, Y, 13)}" fill="${mix(C, "#000000", 0.3)}" stroke="${lens.P.outline}" stroke-width="9" stroke-linejoin="round" paint-order="stroke"/>` +
    `<path d="${band(span, Y, 4.5)}" fill="${mix(C, "#ffffff", 0.45)}"/>`
  )
}

function stitching(lens: Lens, Y: Axis): string {
  const line = (side: number, dy: number): string => {
    const [a, b] = strapSpan(lens, side, 46)
    return `<path d="M${f2(a)} ${Y(dy)}L${f2(b)} ${Y(dy)}" fill="none" stroke="${STITCH}" stroke-width="2" stroke-dasharray="5 4"/>`
  }
  return line(-1, -7) + line(-1, 7) + line(1, -7) + line(1, 7)
}
