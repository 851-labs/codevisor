import type { Point } from "./geometry/math.js"

export type EyeMode = "open" | "squeeze" | "mad"

export interface LegPose {
  readonly rot?: number
  readonly lift?: number
  readonly dx?: number
  readonly bend?: number
  readonly stretch?: number
}

export interface FacePose {
  readonly turn?: number
  readonly up?: number
  readonly blink?: number
  readonly mode?: EyeMode
  readonly wide?: number
  readonly glint?: number
  readonly brow?: number | undefined
}

export interface HatPose {
  readonly kind: string
  readonly color?: string
  readonly rot?: number
  readonly dy?: number
  readonly spin?: number
  readonly tipX?: number
  readonly tipY?: number
}

export interface MakeupChoice {
  readonly blush?: boolean
  readonly freckles?: boolean
  readonly lashes?: boolean
}

export interface WearPose {
  readonly eyewear?: string
  readonly eyewearColor?: string
  readonly eyewearOp?: number
  readonly eyewearDy?: number
  readonly outfit?: string
  readonly outfitColor?: string
  readonly clothesOp?: number
  readonly makeup?: MakeupChoice
  readonly blushColor?: string
  readonly tips?: ReadonlyArray<Point>
}

export interface DotEffect {
  readonly kind: "dot" | "puff"
  readonly x: number
  readonly y: number
  readonly r: number
  readonly op: number
}

export interface ClipboardEffect {
  readonly kind: "clipboard"
  readonly tt: number
  readonly pop: number
  readonly nod: number
  readonly op: number
}

export interface CallingEffect {
  readonly kind: "calling"
  readonly t: number
  readonly op: number
}

export interface SleepZEffect {
  readonly kind: "z"
  readonly x: number
  readonly y: number
  readonly size: number
  readonly rot: number
  readonly op: number
}

export type Effect = DotEffect | ClipboardEffect | CallingEffect | SleepZEffect

export interface BotMascotPose {
  readonly y?: number
  readonly lean?: number
  readonly sy?: number
  readonly tilt?: number
  readonly twist?: number
  readonly shift?: number
  readonly spin?: number
  readonly L?: LegPose
  readonly R?: LegPose
  readonly face?: FacePose
  readonly fx?: ReadonlyArray<Effect>
  readonly hat?: HatPose
  readonly wear?: WearPose
}
