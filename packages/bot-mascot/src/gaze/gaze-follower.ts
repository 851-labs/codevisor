import { officialBodyZones } from "../body/zones.js"
import { EYE_Y } from "../face/eye-shape.js"
import { clamp, distance, TAU, type Point } from "../geometry/math.js"
import type { BotMascotGaze } from "./gaze.js"

export interface GazeEasing {
  readonly followHz: number
  readonly returnHz: number
  readonly engageHz: number
  readonly releaseHz: number
  readonly stillAfter: number
}

export const GAZE_EASING: GazeEasing = {
  followHz: 2.4,
  returnHz: 0.45,
  engageHz: 2,
  releaseHz: 0.35,
  stillAfter: 2.5
}

const MOVED = 1.5
const MAX_STEP = 0.25
const SUBSTEP = 1 / 120
const RELEASED = 0.003

interface Spring {
  x: number
  v: number
}

export class GazeFollower {
  private point: readonly [Spring, Spring] | null = null
  private readonly weight: Spring = { x: 0, v: 0 }
  private last: Point | null = null
  private still = 0

  constructor(
    private readonly origin: Point = [250, EYE_Y - officialBodyZones.dy],
    private readonly easing: GazeEasing = GAZE_EASING
  ) {}

  step(target: Point | null, dt: number): BotMascotGaze | null {
    const seconds = clamp(dt, 0, MAX_STEP)
    this.watch(target, seconds)
    const aim = this.still < this.easing.stillAfter ? target : null
    const point = this.point ?? (aim ? [spring(aim[0]), spring(aim[1])] : null)
    if (!point) return null

    this.point = point
    this.settle(point, aim, seconds)
    if (!aim && this.weight.x < RELEASED) return this.released()

    return { x: point[0].x, y: point[1].x, weight: clamp(this.weight.x, 0, 1) }
  }

  reset(): void {
    this.point = null
    this.weight.x = 0
    this.weight.v = 0
    this.last = null
    this.still = 0
  }

  private watch(target: Point | null, seconds: number): void {
    const moved = target !== null && (!this.last || distance(target, this.last) > MOVED)
    this.still = moved ? 0 : this.still + seconds
    if (moved || !target) this.last = target
  }

  private settle(point: readonly [Spring, Spring], aim: Point | null, seconds: number): void {
    const toward = aim ?? this.origin
    const pointHz = aim ? this.easing.followHz : this.easing.returnHz
    const weightHz = aim ? this.easing.engageHz : this.easing.releaseHz
    for (let left = seconds; left > 1e-9; left -= SUBSTEP) {
      const h = Math.min(SUBSTEP, left)
      pull(point[0], toward[0], pointHz, h)
      pull(point[1], toward[1], pointHz, h)
      pull(this.weight, aim ? 1 : 0, weightHz, h)
    }
  }

  private released(): null {
    this.point = null
    this.weight.x = 0
    this.weight.v = 0
    return null
  }
}

export const gazeFollower = (origin?: Point, easing?: GazeEasing): GazeFollower =>
  new GazeFollower(origin, easing)

const spring = (x: number): Spring => ({ x, v: 0 })

function pull(s: Spring, aim: number, hz: number, h: number): void {
  const w = TAU * hz
  s.v += h * (w * w * (aim - s.x) - 2 * w * s.v)
  s.x += h * s.v
}
