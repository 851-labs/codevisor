import { bodyBottom, bodyTop, type Palette } from "../color/palette.js"
import { bump, f2, s01, TAU } from "../geometry/math.js"
import { hold, lidAt } from "../moods/timing.js"
import type { BotMascotPose, CallingEffect } from "../pose.js"
import type { RenderContext } from "../render/context.js"
import { annoyance, CALL, followHand, phoneAt, rage, yelling } from "./calling-timeline.js"
import { handset, handsetColor } from "./handset.js"

export const CALLING_LOOP = 9

const turnCurve = hold(
  [
    [0, 0],
    [0.8, -0.15],
    [2.3, -0.05],
    [3.4, 0.05],
    [CALL.pull[0], 0.08],
    [CALL.wind[0], 0.3],
    [CALL.fling[0] + 0.05, -0.75],
    [7.6, -0.2],
    [8.3, 0]
  ],
  0.16
)

const upCurve = hold(
  [
    [0, 0.1],
    [0.8, -0.22],
    [2.3, -0.1],
    [CALL.pull[0], -0.05],
    [CALL.wind[0], -0.3],
    [CALL.fling[0] + 0.05, 0.1],
    [7.7, 0.1],
    [8.4, 0]
  ],
  0.18
)

export function callingPose(t: number): BotMascotPose {
  const a = annoyance(t)
  const r = rage(t)
  const y = yelling(t)
  const nods = [1.55, 1.9].reduce((s, k) => s + bump((t - k) / 0.32), 0)
  const ugh = (bump((t - 2.9) / 0.4) + bump((t - 3.6) / 0.4)) * Math.sin(TAU * 4 * t)
  const tremble = (0.5 * r + 1.2 * y) * Math.sin(TAU * 15 * t)
  const pump = y * Math.abs(Math.sin(TAU * 3.2 * (t - CALL.pull[1])))
  const arch = s01((t - CALL.wind[0]) / 0.3) * (1 - s01((t - CALL.fling[0]) / 0.1))
  const whip = s01((t - CALL.fling[0]) / 0.12) * (1 - s01((t - 7.5) / 0.45))
  const huffs = bump((t - CALL.huff) / 0.45) + bump((t - CALL.huff - 0.5) / 0.45)
  const mode = r > 0.5 && t < 7.9 ? "mad" : "open"
  const onCall = 6 * (1 - a) * s01((t - 0.9) / 0.4) * (1 - s01((t - CALL.pull[0]) / 0.3))
  return {
    y: -3 * nods + 6 * pump,
    sy:
      1 +
      0.012 * Math.sin((TAU * t) / 1.6) -
      0.04 * nods -
      0.035 * a +
      0.1 * pump +
      0.05 * y +
      0.05 * arch -
      0.08 * whip +
      0.06 * huffs,
    tilt: onCall + 3 * nods + 3 * ugh + 9 * y + 8 * arch - 11 * whip + tremble,
    shift: 7 * y + 2 * r + 6 * arch - 9 * whip,
    lean: 0.6 * tremble,
    face: {
      turn: turnCurve(t),
      up: upCurve(t) + 0.06 * nods,
      mode,
      blink: Math.min(1 - 0.34 * a, lidAt(t, 0.16, 1.3), lidAt(t, 0.38, CALL.calm + 0.1)),
      brow: a > 0.05 && mode === "open" ? 22 * a : undefined,
      wide: 1 + 0.08 * bump((t - CALL.fling[0]) / 0.4)
    },
    fx: [{ kind: "calling", t, op: 1 }]
  }
}

export function callingSvg(
  ctx: RenderContext,
  P: Palette,
  f: CallingEffect,
  lift: number,
  tilt: number
): string {
  const O = P.outline
  const ph = phoneAt(f.t)
  const sk = `${ctx.idPrefix}calling${ctx.ids.calling++}`
  const S = `stroke="${O}" stroke-width="5" stroke-linejoin="round"`
  const defs = `<defs><linearGradient id="${sk}" x1=".8" y1="0" x2=".2" y2="1"><stop offset="0" stop-color="${bodyTop(P)}"/><stop offset="1" stop-color="${bodyBottom(P)}"/></linearGradient></defs>`
  const receiver = handset(O, handsetColor(P.key))
  const palm = `<rect x="6" y="-19" width="28" height="38" rx="13" fill="url(#${sk})" ${S}/><rect x="-12" y="-24" width="14" height="22" rx="7" fill="url(#${sk})" ${S}/>`
  const fingers = [-12, -1, 10]
    .map(
      (y) => `<rect x="-6" y="${y}" width="28" height="11.5" rx="5.75" fill="url(#${sk})" ${S}/>`
    )
    .join("")
  let inner =
    ph.s > 0.01
      ? `<g transform="translate(${f2(ph.x)} ${f2(ph.y)}) rotate(${f2(ph.rot)}) scale(${(1.15 * ph.s).toFixed(3)})">${ph.held ? palm + receiver + fingers : receiver}</g>`
      : ""
  const ft = followHand(f.t)
  if (ft) {
    if (ft.s > 0.02) inner += ctx.hands(P, { pose: "open", x: ft.x, y: ft.y, rot: ft.rot, s: ft.s })
    if (ft.ring > 0 && ft.ring < 1) inner += ring(O, ft.x, ft.y, ft.ring, 18, 24)
  }
  if (ph.ring !== null && ph.ring > 0 && ph.ring < 1) inner += ring(O, ph.x, ph.y, ph.ring, 18, 26)
  if (!inner) return ""
  const opacity = f.op < 0.999 ? ` opacity="${f2(f.op)}"` : ""
  return (
    defs +
    `<g transform="translate(0 ${f2(-lift - (ctx.body.zoned ? ctx.body.rise : 0))}) rotate(${f2(tilt)} 250 330)"${opacity}>${inner}</g>`
  )
}

function ring(O: string, x: number, y: number, u: number, r0: number, dr: number): string {
  return `<circle cx="${f2(x)}" cy="${f2(y)}" r="${f2(r0 + dr * u)}" fill="none" stroke="${O}" stroke-width="${f2(5 * (1 - u))}" opacity="${f2(0.7 * (1 - u))}"/>`
}
