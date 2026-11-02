import { cyclops } from "../data.js"
import { catmull, clamp, TAU, type Point } from "../geometry/math.js"

export type Radii = ReadonlyArray<number>

export const EYE_COUNT = cyclops.n
export const EYE_WIDTH = cyclops.width
export const EYE_Y = cyclops.y
export const FACE_RADIUS = cyclops.radius
export const BROW = EYE_WIDTH * 0.78

const REST: Point = [250, EYE_Y]

export const lerpRadii = (a: Radii, b: Radii, t: number): Radii =>
  a.map((v, i) => v + (b[i]! - v) * t)

export function radiusAt(r: Radii, th: number): number {
  const x = ((((th % TAU) + TAU) % TAU) / TAU) * EYE_COUNT
  const i = Math.floor(x) % EYE_COUNT
  const f = x - Math.floor(x)
  return r[i]! * (1 - f) + r[(i + 1) % EYE_COUNT]! * f
}

export function eyeShape(t: number, v: number): Radii {
  let r = Math.abs(t) < 1e-6 ? cyclops.centre : sideShape(t)
  if (Math.abs(v) > 1e-6)
    r = lerpRadii(r, v < 0 ? cyclops.up : cyclops.down, Math.min(1, Math.abs(v)))
  return r
}

export function eyePath(r: Radii, x: number, y: number, sx: number, sy: number): string {
  const pts = r.map((rr, i): Point => {
    const a = (TAU * i) / EYE_COUNT
    return [x + Math.cos(a) * rr * sx, y + Math.sin(a) * rr * sy]
  })
  return catmull(pts)
}

export const eyeTheta = (t: number): number => Math.asin(clamp(t, -1, 1) * Math.sin(cyclops.theta))

export interface GlintPlacement {
  readonly x: number
  readonly y: number
  readonly squash: number
  readonly rotation: number
}

export interface EyeFrame {
  readonly x: number
  readonly y: number
  readonly k: number
  readonly b: number
  readonly r: Radii
}

export function placeGlint(
  eye: EyeFrame,
  along: number,
  size: number,
  light: number
): GlintPlacement {
  const { x, y } = eye
  const par = cyclops.glint.parallax
  const ax = REST[0] + Math.cos(light) * along * EYE_WIDTH
  const ay = REST[1] + Math.sin(light) * along * EYE_WIDTH
  let gx = ax + par * (x - REST[0])
  let gy = ay + par * (y - REST[1])
  let dist = Math.hypot(gx - x, gy - y)
  const phi = dist > 1e-6 ? Math.atan2(gy - y, gx - x) : light
  const room = edgeDistance(eye, phi) * 0.9 - size
  let squash = 1
  if (dist > room) {
    squash = Math.max(0.55, 1 - (dist - room) / (2.2 * size))
    dist = Math.max(0, room + size * (1 - squash))
    gx = x + Math.cos(phi) * dist
    gy = y + Math.sin(phi) * dist
  }
  return { x: gx, y: gy, squash, rotation: (phi * 180) / Math.PI }
}

function sideShape(t: number): Radii {
  return lerpRadii(cyclops.centre, t > 0 ? cyclops.right : cyclops.left, Math.min(1, Math.abs(t)))
}

function edgeDistance({ k, b, r }: EyeFrame, phi: number): number {
  const th = Math.atan2(Math.sin(phi) / Math.max(b, 1e-3), Math.cos(phi) / Math.max(k, 1e-3))
  const rr = radiusAt(r, th)
  return Math.hypot(k * rr * Math.cos(th), b * rr * Math.sin(th))
}
