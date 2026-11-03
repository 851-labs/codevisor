import type { Palette } from "../color/palette.js"
import { cyclops } from "../data.js"
import { clamp, f2, s01 } from "../geometry/math.js"
import {
  BROW,
  EYE_WIDTH,
  EYE_Y,
  eyePath,
  eyeShape,
  eyeTheta,
  FACE_RADIUS,
  placeGlint,
  radiusAt,
  type EyeFrame
} from "./eye-shape.js"
import type { FaceState } from "./face-state.js"

export function eyeSvg(P: Palette, f: FaceState, uid: string): string {
  const turn = f.turn || 0
  const v = f.up || 0
  const th = eyeTheta(turn)
  const x = 250 + FACE_RADIUS * Math.sin(th)
  const y = EYE_Y + v * 6
  if (f.mode === "squeeze") return squeezedEye(P, x, y)
  return openEye(P, f, uid, x, y)
}

export function arcEye(P: Palette, x: number, y: number, w: number, h: number, t: number): string {
  const e = h / 2
  return (
    `<path d="M${-w / 2} ${e}C${-w / 2} ${e} ${-0.3 * w} ${-e} 0 ${-e}C${0.3 * w} ${-e} ${w / 2} ${e} ${w / 2} ${e}" ` +
    `transform="translate(${f2(x)} ${f2(y)})" fill="none" stroke="${P.eye}" stroke-width="${t}" stroke-linecap="round" stroke-linejoin="round"/>`
  )
}

function squeezedEye(P: Palette, x: number, y: number): string {
  let out = arcEye(P, x, y + 4, EYE_WIDTH * 0.9, EYE_WIDTH * 0.2, 13)
  for (const dx of [-22, 0, 22]) {
    out += `<path d="M${f2(x + dx)} ${f2(EYE_Y - BROW)}L${f2(x + dx * 1.35)} ${f2(EYE_Y - BROW - 18)}" stroke="${P.eye}" stroke-width="6" stroke-linecap="round"/>`
  }
  return out
}

function openEye(P: Palette, f: FaceState, uid: string, x0: number, y0: number): string {
  const turn = f.turn || 0
  const v = f.up || 0
  const blink = f.blink ?? 1
  const k = Math.cos(eyeTheta(turn))
  const r = eyeShape(turn, v)
  const x = x0 + cyclops.nudge[0] * turn
  const y = y0 + cyclops.nudge[1] * Math.abs(turn)
  const wide = f.wide || 1
  const eye = eyeBall(P, f, uid, { x, y, k: k * wide, b: blink * wide, r }, blink)
  if (f.mode === "mad") return madEye(P, x, eye)
  return brow(P, f, x) + eye
}

function eyeBall(P: Palette, f: FaceState, uid: string, frame: EyeFrame, blink: number): string {
  let eye = `<path d="${eyePath(frame.r, frame.x, frame.y, frame.k, frame.b)}" fill="${P.eye}"/>`
  const shine = (f.glint ?? 1) * s01((blink - 0.3) / 0.2)
  if (shine > 0.01) eye += glints(P, frame, uid, shine)
  if (f.lashes) eye += lashes(P, frame)
  return eye
}

function madEye(P: Palette, x: number, eye: string): string {
  return (
    `<g transform="translate(${f2(x)} ${EYE_Y + 6}) scale(1 .8) translate(${f2(-x)} ${-EYE_Y})">${eye}</g>` +
    `<path d="M${f2(x - BROW)} ${f2(EYE_Y - BROW)}L${f2(x)} ${f2(EYE_Y - BROW + 20)}L${f2(x + BROW)} ${f2(EYE_Y - BROW)}" fill="none" stroke="${P.eye}" stroke-width="10" stroke-linecap="round" stroke-linejoin="round"/>`
  )
}

function brow(P: Palette, f: FaceState, x: number): string {
  if (f.eyewear === "goggles" || !f.brow) return ""
  return `<path d="M${f2(x - BROW * 0.8)} ${f2(EYE_Y - BROW + 6)}L${f2(x + BROW * 0.8)} ${f2(EYE_Y - BROW - 6)}" fill="none" stroke="${P.eye}" stroke-width="8" stroke-linecap="round" transform="rotate(${f.brow} ${f2(x)} ${f2(EYE_Y - BROW)})"/>`
}

function glints(P: Palette, frame: EyeFrame, uid: string, intensity: number): string {
  if (intensity <= 0.01) return ""
  const g = cyclops.glint
  const light = (g.light * Math.PI) / 180
  const main = g.main * EYE_WIDTH * (0.85 + 0.15 * Math.min(Math.max(intensity, 1), 1.25))
  const small = g.bounce * EYE_WIDTH
  const a = placeGlint(frame, g.along, main, light)
  const b = placeGlint(frame, g.bounce_along, small, light + Math.PI)
  const op = Math.min(1, intensity)
  return (
    `<clipPath id="${uid}gc"><path d="${eyePath(frame.r, frame.x, frame.y, frame.k, frame.b)}"/></clipPath><g clip-path="url(#${uid}gc)">` +
    `<ellipse cx="${f2(a.x)}" cy="${f2(a.y)}" rx="${f2(main * a.squash)}" ry="${f2(main)}" transform="rotate(${f2(a.rotation)} ${f2(a.x)} ${f2(a.y)})" fill="${P.glint}" opacity="${f2(op)}"/>` +
    `<ellipse cx="${f2(b.x)}" cy="${f2(b.y)}" rx="${f2(small * b.squash)}" ry="${f2(small)}" transform="rotate(${f2(b.rotation)} ${f2(b.x)} ${f2(b.y)})" fill="${P.glint}" opacity="${f2(op * 0.8)}"/></g>`
  )
}

function lashes(P: Palette, { r, x, y, k: sx, b: sy }: EyeFrame): string {
  let out = ""
  const flip = clamp(sy * 2.2 - 1, -1, 1)
  for (const deg of [-128, -100, -72]) {
    const a = (deg * Math.PI) / 180
    const rr = radiusAt(r, a)
    const px = x + Math.cos(a) * rr * sx
    const py = y + Math.sin(a) * rr * sy
    const dx = Math.cos(a) * 0.9
    const dy = Math.sin(a) * flip
    const n = Math.hypot(dx, dy) || 1
    out += `<path d="M${f2(px)} ${f2(py)}l${f2((dx / n) * 10)} ${f2((dy / n) * 10)}" stroke="${P.eye}" stroke-width="4.5" stroke-linecap="round"/>`
  }
  return out
}
