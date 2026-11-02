import { namedColors } from "../color/colors.js"
import type { Palette } from "../color/palette.js"
import { bump, f2, lerp, s01, TAU } from "../geometry/math.js"
import { lidAt, popIn } from "../moods/timing.js"
import type { BotMascotPose, ThinkEffect } from "../pose.js"
import type { RenderContext } from "../render/context.js"
import { star4 } from "../render/shine.js"

type Triple = readonly [number, number, number]
type IconName = "star" | "heart" | "note"

interface CloudState {
  readonly k: number
  readonly b: readonly [number, number]
  readonly icon: { readonly name: IconName; readonly s: number; readonly wob: number } | null
  readonly burst: number
}

const POP = 0.4
const LOOP = 9
const CLOUD: Triple = [317, 199, 1.1]
const BUBBLES: ReadonlyArray<Triple> = [
  [351, 238, 6],
  [356, 253, 3.6]
]
const ICONS: ReadonlyArray<readonly [IconName, number]> = [
  ["star", 0.55],
  ["heart", 2.25],
  ["note", 3.95]
]
const SHOW = 1.45
const AHA = 5.5
const BACK = [7.2, 7.75] as const
const CHIN: Triple = [236, 331, 122]
const UP: Triple = [176, 224, 158]
const SWING: Triple = [118, 330, 145]
const LOBES: ReadonlyArray<Triple> = [
  [-13, -1, 12],
  [0, -7, 17],
  [16, 3, 14],
  [3, 10, 14]
]
const BURST: ReadonlyArray<readonly [number, number]> = [
  [-100, 1],
  [-45, 0.9],
  [10, 1],
  [60, 0.8]
]

export function thinkingPose(t: number): BotMascotPose {
  const tt = thinkingTime(t)
  const a = aha(tt)
  const hmm = ICONS.reduce((s, [, k]) => s + bump((tt - k + 0.1) / 0.35), 0)
  const hop = bump((tt - AHA) / 0.42)
  const land = bump((tt - AHA - 0.4) / 0.25)
  const glance = ICONS.reduce(
    (s, [, k]) => s + s01((tt - k) / 0.12) * (1 - s01((tt - k - 0.7) / 0.5)),
    0
  )
  const back = s01((tt - BACK[0]) / 0.6)
  const a2 = s01((tt - AHA - 0.16) / 0.12) * (1 - s01((tt - BACK[0]) / 0.5))
  const turn = lerp(0.45 + 0.06 * glance + 0.04 * Math.sin((TAU * tt) / 3.1), 0.05, a2)
  const up = lerp(-0.66 - 0.05 * glance, -0.25, a2)
  const blink = Math.min(lidAt(tt, 0.16, 1.6, 4.9, 8.2), lidAt(tt, 0.2, BACK[0] + 0.3))
  return {
    y: 12 * hop,
    sy: 1 + 0.012 * Math.sin((TAU * t) / 1.8) - 0.03 * hmm + 0.07 * hop - 0.06 * land,
    tilt: (-4 - 1.5 * hmm) * (1 - a) + 3 * a * Math.sin(TAU * 1.1 * (tt - AHA)) * (1 - back),
    shift: -2 * (1 - a),
    face: {
      turn,
      up,
      blink,
      mode: "open",
      wide: 1 + 0.24 * a2 * (1 - 0.3 * s01((tt - AHA - 0.6) / 0.5)),
      thinkBrow: 0.6 + 0.12 * hmm + 0.3 * a2
    },
    fx: [{ kind: "think", tt, pop: t < POP ? t / POP : 1, op: 1 }]
  }
}

export function thinkingSvg(
  ctx: RenderContext,
  P: Palette,
  f: ThinkEffect,
  lift: number,
  tilt: number,
  sy: number
): string {
  const O = P.outline
  const tt = f.tt
  const c = cloudAt(tt)
  const [hx, hy, hr] = handAt(tt)
  const k = f.pop < 1 ? popIn(f.pop, 0, 1) : 1
  const cy = 412 - lift - (412 - CLOUD[1]) * sy
  const out = cloudSvg(O, c, cy, sy, lift)
  let hand = k > 0.01 ? ctx.hands(P, { pose: "indexUp", x: hx, y: hy, rot: hr, s: 0.78 * k }) : ""
  hand += ideaMarks(P, tt, hx, hy, hr)
  if (f.pop < 1 && f.pop > 0) hand += chinRing(O, f.pop)
  if (!out && !hand) return ""
  const g = (inner: string): string =>
    f.op < 0.999 ? `<g opacity="${f2(f.op)}">${inner}</g>` : inner
  return g(out + `<g transform="translate(0 ${f2(-lift)}) rotate(${f2(tilt)} 250 330)">${hand}</g>`)
}

function thinkingTime(t: number): number {
  return t < POP ? 0 : (t - POP) % LOOP
}

function aha(tt: number): number {
  return s01((tt - AHA) / 0.12) * (1 - s01((tt - BACK[0]) / 0.5))
}

function bez(u: number): [number, number, number] {
  const p = [0, 1, 2].map(
    (i) => (1 - u) ** 2 * CHIN[i]! + 2 * u * (1 - u) * SWING[i]! + u * u * UP[i]!
  )
  return [p[0]!, p[1]!, p[2]!]
}

function handAt(tt: number): Triple {
  const taps = ICONS.reduce((a, [, k]) => a + bump((tt - k + 0.15) / 0.3), 0)
  if (tt < AHA) return [CHIN[0], CHIN[1] - 2 * taps, CHIN[2] + 7 * taps]
  if (tt >= BACK[0]) return bez(1 - s01((tt - BACK[0]) / (BACK[1] - BACK[0])))
  const u = (tt - AHA) / 0.26
  const p = bez(u >= 1 ? 1 : s01(u))
  if (u < 1) {
    p[1] -= 8 * bump(u)
  } else {
    const w = tt - AHA - 0.26
    p[1] -= 7 * bump(Math.min(1, w / 0.3))
    p[2] += 5 * Math.sin(TAU * 2.2 * w) * (1 - s01(w / 1.2))
  }
  return p
}

function cloudAt(tt: number): CloudState {
  const gone = s01((tt - AHA - 0.06) / 0.08)
  const swell = 0.04 * s01((tt - AHA) / 0.06)
  const puffs = ICONS.reduce((a, [, k]) => a + bump((tt - k + 0.1) / 0.3), 0)
  const k =
    popIn(tt, 0.25, 0.3, 0.1) *
    (1 + swell + 0.04 * puffs + 0.02 * Math.sin((TAU * tt) / 1.7)) *
    (1 - gone)
  const b = [popIn(tt, 0.0, 0.22) * (1 - gone), popIn(tt, 0.12, 0.22) * (1 - gone)] as const
  let icon: CloudState["icon"] = null
  for (const [name, a] of ICONS) {
    if (tt < a || tt > a + SHOW + 0.2) continue
    const out = name === "note" ? 1 - gone : 1 - s01((tt - a - SHOW) / 0.2)
    icon = { name, s: popIn(tt, a, 0.28) * out, wob: Math.sin(TAU * 0.9 * (tt - a)) }
  }
  const burst = tt > AHA + 0.08 && tt < AHA + 0.68 ? (tt - AHA - 0.08) / 0.6 : 0
  return { k, b, icon, burst }
}

function cloudSvg(O: string, c: CloudState, cy: number, sy: number, lift: number): string {
  const [cx, , ck] = CLOUD
  const Y = (y: number): number => 412 - lift - (412 - y) * sy
  let out = ""
  for (const [i, [bx, by, br]] of BUBBLES.entries()) {
    const scale = c.b[1 - i]!
    if (scale > 0.01)
      out += `<circle cx="${bx}" cy="${f2(Y(by))}" r="${f2(br * scale)}" fill="#fff" stroke="${O}" stroke-width="${i ? 4 : 4.5}"/>`
  }
  if (c.k > 0.01) {
    out +=
      `<g transform="translate(${cx} ${f2(cy)}) scale(${f2(ck * c.k)})">` +
      LOBES.map(
        ([x, y, r]) =>
          `<circle cx="${x}" cy="${y}" r="${r}" fill="${O}" stroke="${O}" stroke-width="10"/>`
      ).join("") +
      LOBES.map(([x, y, r]) => `<circle cx="${x}" cy="${y}" r="${r}" fill="#fff"/>`).join("") +
      `</g>`
  }
  if (c.icon && c.icon.s > 0.01 && c.k > 0.01) {
    out += `<g transform="translate(${cx} ${f2(cy + 2)}) rotate(${f2(6 * c.icon.wob)}) scale(${f2(ck * c.icon.s * Math.min(1, c.k))})">${iconSvg(c.icon.name, O)}</g>`
  }
  if (c.burst > 0) out += burstSvg(O, c.burst, cx, cy)
  return out
}

function burstSvg(O: string, u: number, cx: number, y0: number): string {
  let out = ""
  for (const [a, d] of BURST) {
    const r = (a * Math.PI) / 180
    const dist = 22 + 30 * (1 - (1 - u) ** 2) * d
    out += star4(
      cx + Math.cos(r) * dist,
      y0 + Math.sin(r) * dist,
      10 * (1 - u) + 2,
      namedColors.yellow,
      O,
      1 - s01((u - 0.5) / 0.5),
      20 * u
    )
  }
  return out
}

function iconSvg(name: IconName, O: string): string {
  const S = `stroke="${O}" stroke-width="4" stroke-linejoin="round"`
  if (name === "star") return `<path d="${starIcon()}Z" fill="${namedColors.yellow}" ${S}/>`
  if (name === "heart")
    return `<path d="M0 13C-12 5 -16 -1 -15 -6C-14 -13 -5 -15 0 -8C5 -15 14 -13 15 -6C16 -1 12 5 0 13Z" fill="${namedColors.red}" ${S}/>`
  return (
    `<path d="M3 7V-13L12 -9" fill="none" stroke="${O}" stroke-width="5" stroke-linecap="round" stroke-linejoin="round"/>` +
    `<ellipse cx="-3" cy="8" rx="7.5" ry="5.8" transform="rotate(-22 -3 8)" fill="${namedColors.blue}" ${S}/>`
  )
}

function starIcon(): string {
  let d = ""
  for (let i = 0; i < 10; i++) {
    const a = -Math.PI / 2 + (i * Math.PI) / 5
    const r = i % 2 ? 7 : 16
    d += `${i ? "L" : "M"}${f2(r * Math.cos(a))} ${f2(r * Math.sin(a))}`
  }
  return d
}

function ideaMarks(P: Palette, tt: number, hx: number, hy: number, hr: number): string {
  const m = tt > AHA + 0.18 && tt < AHA + 0.9 ? (tt - AHA - 0.18) / 0.72 : 0
  if (m <= 0) return ""
  const ra = (hr * Math.PI) / 180
  const tip = [
    hx + 0.78 * (-11.5 * Math.cos(ra) + 46 * Math.sin(ra)),
    hy + 0.78 * (-11.5 * Math.sin(ra) - 46 * Math.cos(ra))
  ] as const
  const grow = s01(m / 0.3)
  const op = 1 - s01((m - 0.6) / 0.4)
  let out = ""
  for (const a of [-150, -105, -60]) {
    const r = (a * Math.PI) / 180
    const r0 = 14 + 6 * grow
    const r1 = r0 + 12 * grow
    out += `<path d="M${f2(tip[0] + Math.cos(r) * r0)} ${f2(tip[1] + Math.sin(r) * r0)}L${f2(tip[0] + Math.cos(r) * r1)} ${f2(tip[1] + Math.sin(r) * r1)}" stroke="${P.eye}" stroke-width="5" stroke-linecap="round" opacity="${f2(op)}"/>`
  }
  return out
}

function chinRing(O: string, pop: number): string {
  return `<circle cx="${CHIN[0]}" cy="${CHIN[1]}" r="${f2(14 + 14 * pop)}" fill="none" stroke="${O}" stroke-width="${f2(5 * (1 - pop))}" opacity="${f2(0.7 * (1 - pop))}"/>`
}
