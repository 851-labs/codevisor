import { mix } from "../color/colors.js"
import { bodyBottom, type Palette } from "../color/palette.js"
import { cyclops } from "../data.js"
import { f2 } from "../geometry/math.js"
import { eyeTheta, FACE_RADIUS } from "./eye-shape.js"
import type { FaceState } from "./face-state.js"

export interface MakeupItem {
  readonly title: string
  readonly colors?: "blush"
}

export const makeupItems = {
  blush: { title: "Blush", colors: "blush" },
  freckles: { title: "Freckles" },
  lashes: { title: "Lashes" }
} as const satisfies Readonly<Record<string, MakeupItem>>

const FRECKLES: ReadonlyArray<readonly [number, number, number]> = [
  [-9, -9, 2.3],
  [0, -13, 2.6],
  [9, -9, 2.3],
  [4, -4, 1.8]
]

export function makeupSvg(P: Palette, f: FaceState, uid: string): string {
  const th = eyeTheta(f.turn || 0)
  let out = ""
  for (const phi of [-cyclops.cheek.phi, cyclops.cheek.phi]) {
    const a = th + phi
    const k = Math.cos(a)
    const cx = 250 + FACE_RADIUS * Math.sin(a)
    if (k <= 0.2) continue
    if (f.blush) out += blush(P, f, uid, cx, k)
    if (f.freckles) out += freckles(P, cx, k)
  }
  return out
}

function blush(P: Palette, f: FaceState, uid: string, cx: number, k: number): string {
  const c = cyclops.cheek
  return `<ellipse cx="${f2(cx)}" cy="${c.y}" rx="${f2(c.rx * k)}" ry="${c.ry}" fill="${f.blushColor || P.cheek}" fill-opacity="${f.blushColor ? 0.7 : 1}" filter="url(#${uid}b4)" opacity="${f2(Math.min(1, k * 1.3))}"/>`
}

function freckles(P: Palette, cx: number, k: number): string {
  const fc = mix(P.outline.slice(0, 7), bodyBottom(P).slice(0, 7), 0.45)
  return FRECKLES.map(
    ([dx, dy, r]) =>
      `<circle cx="${f2(cx + dx * k)}" cy="${f2(cyclops.cheek.y + dy)}" r="${f2(r * (0.6 + 0.4 * k))}" fill="${fc}" fill-opacity=".6"/>`
  ).join("")
}
