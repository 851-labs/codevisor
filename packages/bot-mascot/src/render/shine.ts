import type { Palette } from "../color/palette.js"
import { f2 } from "../geometry/math.js"

export const glint = (d: string, w = 4.5): string =>
  `<path d="${d}" fill="none" stroke="#fff" stroke-opacity=".92" stroke-width="${w}" stroke-linecap="round"/>`

export const glintDot = (x: number, y: number, r = 2.2): string =>
  `<circle cx="${f2(x)}" cy="${f2(y)}" r="${r}" fill="#fff" fill-opacity=".92"/>`

export const star5 = (
  P: Palette,
  x: number,
  y: number,
  r: number,
  fill = "#F5C842",
  rot = 0
): string => {
  let d = ""
  for (let i = 0; i < 10; i++) {
    const a = ((i * 36 - 90 + rot) * Math.PI) / 180
    const rr = i % 2 ? r * 0.45 : r
    d += `${i ? "L" : "M"}${f2(x + Math.cos(a) * rr)} ${f2(y + Math.sin(a) * rr)}`
  }
  return `<path d="${d}Z" fill="${fill}" stroke="${P.outline}" stroke-width="2.4" stroke-linejoin="round"/>`
}

export const arcD = (
  cx: number,
  cy: number,
  rx: number,
  ry: number,
  a0: number,
  a1: number
): string => {
  let d = ""
  for (let i = 0; i <= 10; i++) {
    const a = ((a0 + ((a1 - a0) * i) / 10) * Math.PI) / 180
    d += `${i ? "L" : "M"}${f2(cx + Math.cos(a) * rx)} ${f2(cy + Math.sin(a) * ry)}`
  }
  return d
}
