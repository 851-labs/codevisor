import { poseArm, type Matrix, type PosedArm } from "../arms/arm-pose.js"
import { growFor, type Torso } from "../arms/rig-arm.js"
import { drawRig, phoneProp } from "../arms/rig-draw.js"
import type { HandOptions } from "../effects/hands.js"
import { smootherstep, type Point } from "../geometry/math.js"
import { botMascotMoods } from "../moods/moods.js"
import type { BotMascotPose } from "../pose.js"
import { renderContext, withHands, type RenderContext } from "../render/context.js"
import { renderFrame, type Backdrop, type FrameOptions } from "../render/frame.js"
import { appendBeforeClose, svgBody, svgTransform } from "../render/svg-parts.js"
import { phoneLeaving } from "./calling-exit.js"
import {
  followThrough,
  phoneFlight,
  RELEASE,
  STILL_PHONE,
  TUCK,
  warp,
  WIND,
  FLING
} from "./calling-flight.js"
import { EAR, PICKED_UP, pickUpScene, type PhoneScene } from "./calling-ground.js"
import {
  apply,
  IDENTITY,
  invert,
  matrixText,
  multiply,
  parseTransform,
  placement
} from "./matrix.js"

export const CALLING_SWAP_LOOP = 9

export interface CallingSwapOptions {
  readonly viewBox?: string
  readonly uid?: string
  readonly size?: number
  readonly backdrop?: Backdrop
  readonly pose?: BotMascotPose
  readonly exit?: number
  readonly phone?: PhoneScene
}

export interface OriginalCalling {
  readonly s: string
  readonly pose: BotMascotPose
  readonly OM: Matrix
  readonly TF: Matrix
  readonly held: boolean
  readonly phoneGroup: string | null
  readonly phoneTransform: string | null
  readonly phoneM: Matrix | null
  readonly open: { readonly p: Point; readonly s: number } | null
}

export interface Scene {
  arm: PosedArm | null
  flying: string
}

const OUTER = /<g transform="(translate\(0 [-\d.]+\) rotate\([-\d.]+ 250 330\))"/
const PHONE =
  /<g transform="(translate\([-\d.]+ [-\d.]+\) rotate\([-\d.]+\) scale\([-\d.]+\))">([^]*?)<\/g>/
const HELD = /fill="url\(#[^")]*calling\d+\)"/
const RING =
  /<circle cx="[-\d.]+" cy="[-\d.]+" r="[-\d.]+" fill="none" stroke="[^"]+" stroke-width="[-\d.]+" opacity="[-\d.]+"\/>/g
const tipsAtRelease = new Map<string, Point>()

export const callingSwapPose = (t0: number): BotMascotPose => botMascotMoods.calling.pose(warp(t0))

export function renderCallingSwap(
  ctx: RenderContext,
  pal: string,
  t0: number,
  o: CallingSwapOptions = {}
): string {
  const uid = o.uid || "cs"
  const t = warp(t0)
  const frame = {
    viewBox: o.viewBox || "0 0 500 500",
    uid,
    ...(o.size ? { size: o.size } : {}),
    ...(o.backdrop ? { backdrop: o.backdrop } : {})
  }
  const f = originalCalling(ctx, pal, t, frame, o.pose)
  const torso = { d: svgBody(f.s), shoulderY: ctx.body.shoulderY }
  let s = f.s.replace(RING, "")
  const staged = o.phone ?? (t0 < PICKED_UP ? pickUpScene(t0) : undefined)
  if (f.phoneGroup && (staged || f.held || t >= WIND[0])) s = s.replace(f.phoneGroup, "")
  let scene = staged ? phoneScene(torso, f, pal, staged) : onTheCall(torso, f, pal, t)
  const follow = t >= RELEASE ? followingThrough(ctx, torso, f, pal, t) : undefined
  if (follow !== undefined) scene = { ...scene, arm: follow }
  if (o.exit != null)
    scene = phoneLeaving(torso, f.TF, scene.arm, scene.flying, phoneProp(pal), o.exit)
  if (!scene.arm?.arm) return scene.flying ? appendBeforeClose(s, scene.flying) : s
  const rig = { uid: `${uid}a`, pal, pose: f.pose, underHands: scene.flying }
  return drawRig(ctx, s, [scene.arm], rig)
}

export function originalCalling(
  ctx: RenderContext,
  pal: string,
  t: number,
  frame: FrameOptions,
  pose?: BotMascotPose
): OriginalCalling {
  let open: HandOptions | null = null
  const catching = withHands(ctx, (_P, h) => {
    open = h
    return ""
  })
  const drawn = pose || botMascotMoods.calling.pose(t)
  const s = renderFrame(catching, pal, drawn, frame)
  const outer = OUTER.exec(s)
  const ph = PHONE.exec(s)
  const OM = outer?.[1] ? parseTransform(outer[1]) : IDENTITY
  const TF = parseTransform(svgTransform(s))
  const caught: HandOptions | null = open
  return {
    s,
    pose: drawn,
    OM,
    TF,
    held: !!(ph && HELD.test(ph[2] ?? "")),
    phoneGroup: ph?.[0] ?? null,
    phoneTransform: ph?.[1] ?? null,
    phoneM: ph?.[1] ? multiply(OM, parseTransform(ph[1])) : null,
    open: openHand(OM, caught)
  }
}

function openHand(OM: Matrix, h: HandOptions | null): OriginalCalling["open"] {
  if (!h || !((h.s ?? 1) > 0.01)) return null
  return { p: apply(OM, [h.x, h.y]), s: h.s ?? 1 }
}

const phoneSvg = (M: Matrix, svg: string): string =>
  `<g transform="matrix(${matrixText(M)})">${svg}</g>`

function holding(torso: Torso, pal: string, propM: Matrix, grow = 1): PosedArm | null {
  return poseArm(torso, { side: 1, grow, grip: phoneProp(pal), propM })
}

export function phoneScene(torso: Torso, f: OriginalCalling, pal: string, ps: PhoneScene): Scene {
  const toBody = invert(f.TF)
  const M = multiply(f.OM, placement(ps.q))
  if (ps.hold === "held")
    return { arm: withHand(holding(torso, pal, multiply(toBody, M)), ps.hand), flying: "" }
  const flying = ps.q.k > 0.01 ? phoneSvg(M, phoneProp(pal).svg) : ""
  if (!(ps.arm > 0.005)) return { arm: null, flying }
  const grip = holding(
    torso,
    pal,
    multiply(toBody, multiply(f.OM, placement({ ...ps.q, k: EAR.k })))
  )
  if (!grip) return { arm: null, flying }
  const reaching = poseArm(torso, {
    side: 1,
    grow: growFor(ps.arm),
    target: grip.tip,
    grip: phoneProp(pal)
  })
  return { arm: reaching ? emptyHanded(reaching, ps.hand) : null, flying }
}

function onTheCall(torso: Torso, f: OriginalCalling, pal: string, t: number): Scene {
  const toBody = invert(f.TF)
  const none = { arm: null, flying: "" }
  if (!(f.phoneGroup || (t >= WIND[0] && t < FLING[1] + 0.3))) return none
  if (t < WIND[0] && f.held && f.phoneM)
    return { arm: holding(torso, pal, multiply(toBody, f.phoneM)), flying: "" }
  if (t < WIND[0]) return none
  const q = phoneFlight(f.phoneTransform ?? STILL_PHONE, f.held, t)
  const M = multiply(f.OM, placement(q))
  if (q.held) return { arm: holding(torso, pal, multiply(toBody, M)), flying: "" }
  return { arm: null, flying: phoneSvg(M, phoneProp(pal).svg) }
}

function followingThrough(
  ctx: RenderContext,
  torso: Torso,
  f: OriginalCalling,
  pal: string,
  t: number
): PosedArm | null | undefined {
  const g = 1 - smootherstep((t - TUCK) / 0.42)
  if (!(g > 0.005)) return undefined
  const tip = tipAtRelease(ctx, pal)
  const b = apply(invert(f.TF), followThrough(tip, ctx.body.zones?.dy ?? 0, Math.min(t, TUCK)))
  return poseArm(torso, { side: 1, grow: g, target: b })
}

function tipAtRelease(ctx: RenderContext, pal: string): Point {
  const zones = ctx.body.zones
  const key = zones ? `${zones.dy}|${zones.y0}` : "-"
  const cached = tipsAtRelease.get(key)
  if (cached) return cached
  const tr = RELEASE - 1e-4
  const fresh = renderContext({ zones })
  const f = originalCalling(fresh, pal, tr, { viewBox: "0 0 500 500", uid: "rl" })
  const torso = { d: svgBody(f.s), shoulderY: fresh.body.shoulderY }
  const q = phoneFlight(f.phoneTransform ?? STILL_PHONE, f.held, tr)
  const p = holding(torso, pal, multiply(invert(f.TF), multiply(f.OM, placement(q))))
  const tip = apply(f.TF, p?.tip ?? [0, 0])
  tipsAtRelease.set(key, tip)
  return tip
}

function withHand(p: PosedArm | null, hand: number): PosedArm | null {
  return p?.over ? { ...p, over: p.over * hand } : p
}

function emptyHanded(p: PosedArm, hand: number): PosedArm {
  const { side, arm, tip, tipDir, layer } = p
  const over = (p.over ?? 0) * hand
  return { side, arm, tip, tipDir, layer, ...(over > 0 ? { over } : {}) }
}
