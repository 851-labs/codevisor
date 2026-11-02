import { poseArm } from "../arms/arm-pose.js"
import { compose, type ComposeItem } from "../arms/compose.js"
import { clipboardPopScale } from "../effects/clipboard.js"
import type { HandOptions } from "../effects/hands.js"
import { f2, lerp2, s01, smootherstep, type Point } from "../geometry/math.js"
import { blendPoses, botMascotMoods, idleAt } from "../moods/moods.js"
import type { BotMascotPose } from "../pose.js"
import { withHands, type RenderContext } from "../render/context.js"
import { renderFrame, type Backdrop, type FrameOptions } from "../render/frame.js"
import { svgBody, withSize } from "../render/svg-parts.js"
import { flipState, holdPoint, type FlipState } from "./working-flip.js"

export interface WorkingTimes {
  readonly in: number
  readonly out: number
  readonly end?: number
  readonly swing?: number
}

export interface ArmsFrameState {
  readonly pose: BotMascotPose
  readonly w: number
  readonly tw: number | null
}

export interface IdleWorkingOptions {
  readonly mode?: "idle" | "working"
  readonly state?: ArmsFrameState
  readonly edit?: (pose: BotMascotPose) => BotMascotPose
  readonly size?: number
  readonly backdrop?: Backdrop
}

export const IDLE_WORKING_TIMES: Required<WorkingTimes> = {
  in: 2.0,
  out: 11.3,
  end: 13.4,
  swing: 0.65
}

interface Board {
  readonly k: number
  readonly ny: number
}

const BOARD_CLIP = /(<rect x="238" y="[^"]*"[^>]*fill="#AEB4C0"[^>]*\/>)/
const workingPose = botMascotMoods.working.pose

export function armsFrameState(t: number, at: WorkingTimes = IDLE_WORKING_TIMES): ArmsFrameState {
  const swing = at.swing ?? 0.65
  const tw = t - at.in
  const I = idleAt(t)
  if (t < at.in) return { pose: I, w: 0, tw: null }

  const W = workingPose(Math.max(0, tw))
  if (t < at.out) {
    return {
      pose: { ...blendPoses(I, W, s01((t - at.in) / 0.45)), fx: W.fx ?? [] },
      w: smootherstep((t - at.in) / swing),
      tw
    }
  }
  const pop = Math.max(0, 1 - (t - at.out) / 0.35)
  const fx = (W.fx || []).map((f) => ({ ...f, pop }))
  const W2 = { ...W, fx }
  return {
    pose: { ...blendPoses(W2, I, s01((t - at.out) / 0.5)), fx },
    w: 1 - smootherstep((t - at.out) / swing),
    tw
  }
}

export function renderIdleWorking(
  ctx: RenderContext,
  pal: string,
  t: number,
  viewBox: string,
  uid: string,
  opts: IdleWorkingOptions = {}
): string {
  const st = stateFor(opts, t)
  const drawn =
    st.tw === null
      ? { s: renderFrame(ctx, pal, st.pose, frameOptions(viewBox, uid, opts)), board: null }
      : working(ctx, pal, frameOptions(viewBox, uid, opts), st.pose)
  if (!drawn.board || st.w <= 0) return withSize(drawn.s, opts.size)

  const body = svgBody(drawn.s)
  const board = drawn.board
  const onBoard = ([x, y]: Point): Point => toBody([x, y + board.ny], st.pose)
  const tt = (st.tw ?? 0) >= 0.4 ? ((st.tw ?? 0) - 0.4) % 12 : -1
  const fl = tt >= 0 ? flipState(tt) : { f: 0 }
  const items = holdingArms(body, ctx, st, fl, onBoard, t)
  const between = {
    at: BOARD_CLIP,
    transform: `translate(250 350) scale(${(1 / board.k).toFixed(5)}) translate(-250 ${f2(-(350 + board.ny))})`
  }
  const s = compose(ctx, drawn.s, items, { uid, pal, blush: st.w, between, pose: st.pose }).svg
  return withSize(s, opts.size)
}

function frameOptions(viewBox: string, uid: string, opts: IdleWorkingOptions): FrameOptions {
  return { viewBox, uid, ...(opts.backdrop ? { backdrop: opts.backdrop } : {}) }
}

function stateFor(opts: IdleWorkingOptions, t: number): ArmsFrameState {
  const st = opts.state || modeState(opts.mode, t)
  return opts.edit ? { ...st, pose: opts.edit(st.pose) } : st
}

function modeState(mode: IdleWorkingOptions["mode"], t: number): ArmsFrameState {
  if (mode === "idle") return { pose: idleAt(t), w: 0, tw: null }
  if (mode === "working") return { pose: workingPose(t), w: 1, tw: t }
  return armsFrameState(t)
}

function working(
  ctx: RenderContext,
  pal: string,
  frame: FrameOptions,
  pose: BotMascotPose
): { s: string; board: Board | null } {
  const calls: Array<HandOptions> = []
  const recording = withHands(ctx, (_P, o) => {
    calls.push(o)
    return ""
  })
  const s = renderFrame(recording, pal, pose, frame)
  const f = pose.fx?.[0]
  if (!f || f.kind !== "clipboard" || calls.length !== 2) return { s, board: null }
  return { s, board: { k: clipboardPopScale(f.pop), ny: 1.5 * f.nod - (pose.y || 0) } }
}

function holdingArms(
  body: string,
  ctx: RenderContext,
  st: ArmsFrameState,
  fl: FlipState,
  onBoard: (p: Point) => Point,
  t: number
): ReadonlyArray<ComposeItem> {
  const torso = { d: body, shoulderY: ctx.body.shoulderY }
  const items: Array<ComposeItem> = []
  for (const side of [-1, 1]) {
    const flips = side > 0 && fl.f > 0 && fl.target !== undefined
    const target =
      flips && fl.target ? lerp2(holdPoint(side), fl.target, Math.min(1, st.w)) : holdPoint(side)
    const p = poseArm(torso, { side, grow: st.w, target: onBoard(target), t })
    if (!p?.arm) continue
    items.push({ side, arm: p.arm, layer: flips ? (fl.layer ?? "front") : "front" })
  }
  return items
}

function toBody(p: Point, pose: BotMascotPose): Point {
  const sy = pose.sy ?? 1
  const sx = 2 - sy
  const lift = pose.y || 0
  return [250 + (p[0] - 250) / sx, 412 + (p[1] - (412 - lift)) / sy]
}
