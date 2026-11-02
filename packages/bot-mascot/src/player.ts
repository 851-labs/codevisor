import { CALLING_EXIT } from "./animations/calling-exit.js"
import { CALLING_SWAP_LOOP, callingSwapPose, renderCallingSwap } from "./animations/calling-swap.js"
import {
  armsFrameState,
  renderIdleWorking,
  type ArmsFrameState,
  type WorkingTimes
} from "./animations/idle-working.js"
import type { BodyZones } from "./body/zones.js"
import {
  hatOf,
  portraitViewBox,
  resolveConfig,
  wearOf,
  type BotMascotConfig,
  type ResolvedBotMascotConfig
} from "./config.js"
import { dangle, type DanglingEnd } from "./drapes/dangle.js"
import { DrapeSwings } from "./drapes/redrape.js"
import { s01 } from "./geometry/math.js"
import { hatRider } from "./hats/hat-rider.js"
import { hatItem } from "./hats/hats.js"
import { blendPoses, botMascotMoods } from "./moods/moods.js"
import { outfitItem } from "./outfits/outfits.js"
import type { BotMascotPose } from "./pose.js"
import { CALLING_STILL } from "./render-static.js"
import { renderContext, type RenderContext } from "./render/context.js"

export interface BotMascotPlayerOptions {
  readonly config?: BotMascotConfig
  readonly now?: number
  readonly reducedMotion?: boolean
  readonly zones?: BodyZones | null
  readonly uid?: string
}

interface CallingFrame {
  readonly tc: number
  readonly pose: BotMascotPose
  readonly exit?: number
}

interface CallState {
  start: number | null
  out: number | null
  tc: number
  from: BotMascotPose | null
}

const NO_WORK: WorkingTimes = { in: Infinity, out: Infinity }
const HAT_DROP_ON_CHANGE = 190

export class BotMascotPlayer {
  private config: ResolvedBotMascotConfig
  private readonly reducedMotion: boolean
  private readonly zones: BodyZones | null | undefined
  private readonly uid: string
  private readonly hat = hatRider()
  private readonly swings = new DrapeSwings()
  private readonly clock0: number
  private last = 0
  private armsMood: string | null = null
  private armsAt: WorkingTimes | null = null
  private readonly call: CallState = { start: null, out: null, tc: 0, from: null }
  private shown: BotMascotPose | null = null
  private eyewearAt = 0
  private clothesAt = 0
  private dangles: { readonly kind: string; readonly ends: ReadonlyArray<DanglingEnd> } | null =
    null

  constructor(options: BotMascotPlayerOptions = {}) {
    this.config = resolveConfig(options.config)
    this.reducedMotion = !!options.reducedMotion
    this.zones = options.zones
    this.uid = options.uid ?? "live"
    this.clock0 = options.now ?? 0
  }

  get current(): ResolvedBotMascotConfig {
    return this.config
  }

  update(patch: BotMascotConfig, now: number): void {
    const next = resolveConfig({ ...this.config, ...patch })
    if (next.eyewear !== this.config.eyewear) this.eyewearAt = next.eyewear !== "none" ? now : 0
    if (next.outfit !== this.config.outfit) {
      this.clothesAt = next.outfit !== "none" ? now : 0
      this.dangles = null
    }
    if (next.hat !== this.config.hat) this.dropHat(next.hat !== "none")
    if (next.mood === this.config.mood && patch.mood === "calling") this.call.start = null
    this.config = next
  }

  frame(now: number, viewBox = portraitViewBox(this.config.hat)): string {
    const dt = this.last ? Math.max(0, now - this.last) / 1000 : 0
    this.last = now
    const ctx = renderContext({ zones: this.zones, swings: this.swings, now, idPrefix: this.uid })
    const { t, st } = this.armsState(now)
    const c = this.callingAt(t, st.pose)
    const pose = this.dangling(
      ctx,
      this.dressed(this.hatted(ctx, c ? c.pose : st.pose, dt), now),
      dt
    )
    this.shown = pose
    const pal = this.config.color
    if (c)
      return renderCallingSwap(ctx, pal, c.tc, {
        viewBox,
        uid: this.uid,
        pose,
        ...(c.exit === undefined ? {} : { exit: c.exit })
      })
    return renderIdleWorking(ctx, pal, t, viewBox, this.uid, { state: { ...st, pose } })
  }

  private dropHat(on: boolean): void {
    this.hat.reset()
    if (on && !this.reducedMotion) this.hat.drop(HAT_DROP_ON_CHANGE)
  }

  private armsState(now: number): { t: number; st: ArmsFrameState } {
    const t = (now - this.clock0) / 1000
    if (this.reducedMotion) return this.stillArms(t)
    const mood = this.config.mood
    if (this.armsMood !== mood) {
      const first = this.armsMood === null
      this.armsMood = mood
      if (mood === "working")
        this.armsAt = {
          in: first
            ? t - 2
            : Math.max(t, this.call.out !== null ? this.call.out + CALLING_EXIT : t),
          out: Infinity
        }
      else if (this.armsAt) this.armsAt = { ...this.armsAt, out: Math.min(this.armsAt.out, t) }
    }
    if (this.armsAt && this.armsAt.out !== Infinity && t > this.armsAt.out + 1) this.armsAt = null
    return { t, st: armsFrameState(t, this.armsAt ?? NO_WORK) }
  }

  private stillArms(t: number): { t: number; st: ArmsFrameState } {
    const still = botMascotMoods.working.still
    if (this.config.mood === "working")
      return { t, st: { pose: botMascotMoods.working.pose(still), w: 1, tw: still } }
    return { t: 0, st: { pose: botMascotMoods.idle.pose(0), w: 0, tw: null } }
  }

  private callingAt(t: number, base: BotMascotPose): CallingFrame | null {
    if (this.reducedMotion)
      return this.config.mood === "calling"
        ? { tc: CALLING_STILL, pose: callingSwapPose(CALLING_STILL) }
        : null
    if (this.config.mood === "calling") return this.onCall(t, base)
    return this.hangingUp(t, base)
  }

  private onCall(t: number, base: BotMascotPose): CallingFrame | null {
    const call = this.call
    if (call.start === null || call.out !== null) {
      call.start = this.armsAt ? this.armsAt.out + 0.9 : t
      call.out = null
      call.from = null
    }
    if (t < call.start) return null
    const tc = (t - call.start) % CALLING_SWAP_LOOP
    const P = callingSwapPose(tc)
    call.from ??= this.shown || base
    const u = s01((t - call.start) / 0.35)
    return { tc, pose: u < 1 ? { ...blendPoses(call.from, P, u), fx: P.fx ?? [] } : P }
  }

  private hangingUp(t: number, base: BotMascotPose): CallingFrame | null {
    const call = this.call
    if (call.start === null) return null
    if (call.out === null) {
      if (t < call.start) {
        call.start = null
        return null
      }
      call.out = t
      call.tc = (t - call.start) % CALLING_SWAP_LOOP
    }
    const u = t - call.out
    if (u >= CALLING_EXIT) {
      call.start = null
      call.out = null
      return null
    }
    const P = callingSwapPose(call.tc)
    return {
      tc: call.tc,
      exit: u,
      pose: { ...blendPoses(P, base, s01(u / CALLING_EXIT)), fx: P.fx ?? [] }
    }
  }

  private hatted(ctx: RenderContext, pose: BotMascotPose, dt: number): BotMascotPose {
    const hat = hatOf(this.config)
    if (!hat) return pose
    if (this.reducedMotion) return { ...pose, hat }
    const h = this.hat.step(ctx.body, pose, dt)
    const worn = { ...pose, hat: { ...hat, ...h } }
    if (!(h.impact > 0.01) || hatItem(hat.kind)?.soft) return worn
    const flinch = Math.min(1, 0.1 + 1.8 * (1 - h.impact))
    return {
      ...worn,
      sy: (pose.sy ?? 1) * (1 - 0.05 * h.impact),
      face: { ...pose.face, blink: Math.min(pose.face?.blink ?? 1, flinch) }
    }
  }

  private dressed(pose: BotMascotPose, now: number): BotMascotPose {
    const eyeIn = this.fadeIn(this.eyewearAt, now, 320)
    return {
      ...pose,
      wear: {
        ...wearOf(this.config),
        eyewearOp: eyeIn,
        eyewearDy: -14 * (1 - eyeIn),
        clothesOp: this.fadeIn(this.clothesAt, now, 380)
      }
    }
  }

  private dangling(ctx: RenderContext, pose: BotMascotPose, dt: number): BotMascotPose {
    const outfit = this.config.outfit
    const hanging = outfitItem(outfit)?.dangles
    if (!hanging || this.reducedMotion) {
      this.dangles = null
      return pose
    }
    if (this.dangles?.kind !== outfit) this.dangles = { kind: outfit, ends: hanging.map(dangle) }
    const tips = this.dangles.ends.map((end) => end.step(ctx.body, pose, dt))
    return { ...pose, wear: { ...pose.wear, tips } }
  }

  private fadeIn(at: number, now: number, ms: number): number {
    return this.reducedMotion || !at ? 1 : s01((now - at) / ms)
  }
}
