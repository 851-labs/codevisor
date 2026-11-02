import { s01, TAU } from "../geometry/math.js"

export type Keyframes = ReadonlyArray<readonly [number, number]>
export type Curve = (t: number) => number

export const hold =
  (keys: Keyframes, ramp = 0.32): Curve =>
  (t) => {
    let v = keys[0]![1]
    for (let i = 1; i < keys.length; i++) {
      const [k, x] = keys[i]!
      if (t >= k) v += (x - v) * s01((t - k) / ramp)
    }
    return v
  }

export function bake(target: Curve, hz: number, z: number, loop: number): Curve {
  const RATE = 120
  const SUB = 4
  const n = Math.round(loop * RATE)
  const w = TAU * hz
  const h = 1 / (RATE * SUB)
  const out = new Float32Array(n)
  let x = target(0)
  let v = 0
  for (let pass = 0; pass < 3; pass++) {
    for (let i = 0; i < n; i++) {
      for (let j = 0; j < SUB; j++) {
        v += h * (w * w * (target((i * SUB + j) * h) - x) - 2 * z * w * v)
        x += h * v
      }
      if (pass === 2) out[i] = x
    }
  }
  return (t) => {
    const u = (((t % loop) + loop) % loop) * RATE
    const i = Math.floor(u)
    const f = u - i
    return out[i % n]! * (1 - f) + out[(i + 1) % n]! * f
  }
}

export const arcHeight = (t: number, a: number, b: number, h: number): number => {
  const u = (t - a) / (b - a)
  return u > 0 && u < 1 ? h * 4 * u * (1 - u) : 0
}

export const lidAt = (t: number, dur: number, ...times: ReadonlyArray<number>): number => {
  let b = 1
  for (const a of times) {
    const u = (t - a) / dur
    if (u > 0 && u < 1) b = Math.min(b, 0.08 + 0.92 * Math.abs(2 * u - 1) ** 1.5)
  }
  return b
}

export const blinkAt = (t: number, ...times: ReadonlyArray<number>): number =>
  lidAt(t, 0.14, ...times)

export const accent = (
  t: number,
  a: number,
  b: number,
  mode: "happy" | "open" | "sleepy",
  close = 0.08,
  open = 0.1
): { readonly mode: "happy" | "open" | "sleepy"; readonly blink: number } => {
  if (t >= a && t < b) return { mode, blink: 1 }
  const lid = t < a ? 0.08 + 0.92 * s01((a - t) / close) : 0.08 + 0.92 * s01((t - b) / open)
  return { mode: "open", blink: lid }
}

export const decay = (t: number, a: number, rate: number, hz: number): number =>
  t > a ? Math.exp(-(t - a) * rate) * Math.cos(TAU * hz * (t - a)) : 0

export const popIn = (t: number, a: number, d = 0.3, o = 0.2): number => {
  const u = (t - a) / d
  if (u <= 0) return 0
  if (u >= 1) return 1
  return s01(u / 0.7) * (1 + o) - o * s01((u - 0.7) / 0.3)
}
