import { defaultBotMascotConfig, type ResolvedBotMascotConfig } from "@codevisor/bot-mascot"

export type ArmMode = "reach" | "direct"
export type ArmPropChoice = "none" | "phone"
export type ArmLayerChoice = "front" | "behind" | "body"
export type Backdrop = "light" | "dark"
export type ArmSide = "left" | "right"
export type View = "outfit" | "animation"
export type Theme = "light" | "dark"
export type Move = "idle" | "working" | "calling" | "hangUp" | "angryHangUp"

export interface ArmControls {
  readonly on: boolean
  readonly mode: ArmMode
  readonly grow: number
  readonly x: number
  readonly y: number
  readonly autoCurl: boolean
  readonly curl: number
  readonly angle: number
  readonly length: number
  readonly bend: number
  readonly prop: ArmPropChoice
  readonly layer: ArmLayerChoice
}

export interface Overlays {
  readonly silhouette: boolean
  readonly edges: boolean
  readonly outline: boolean
  readonly points: boolean
}

export interface RigControls {
  readonly on: boolean
  readonly left: ArmControls
  readonly right: ArmControls
  readonly overlays: Overlays
}

export interface PlaygroundState {
  readonly look: ResolvedBotMascotConfig
  readonly animation: string
  readonly time: number
  readonly playing: boolean
  readonly speed: number
  readonly loop: boolean
  readonly showGaze: boolean
  readonly fps: number
  readonly backdrop: Backdrop
  readonly rig: RigControls
  readonly view: View
  readonly theme: Theme
  readonly follow: boolean
  readonly move: Move
}

export const overlayNames: ReadonlyArray<keyof Overlays> = [
  "outline",
  "silhouette",
  "edges",
  "points"
]
export const armSides: ReadonlyArray<ArmSide> = ["left", "right"]
export const sideSign: Readonly<Record<ArmSide, number>> = { left: -1, right: 1 }
export const armModes: ReadonlyArray<ArmMode> = ["reach", "direct"]
export const armProps: ReadonlyArray<ArmPropChoice> = ["none", "phone"]
export const armLayers: ReadonlyArray<ArmLayerChoice> = ["front", "behind", "body"]
export const backdrops: ReadonlyArray<Backdrop> = ["light", "dark"]
export const views: ReadonlyArray<View> = ["outfit", "animation"]
export const themes: ReadonlyArray<Theme> = ["light", "dark"]
export const moves: ReadonlyArray<Move> = ["idle", "working", "calling", "hangUp", "angryHangUp"]
export const frameRates: ReadonlyArray<number> = [12, 24, 30, 60]
export const speeds: ReadonlyArray<number> = [0.1, 0.25, 0.5, 1, 1.5, 2]

const restingArm = (x: number): ArmControls => ({
  on: false,
  mode: "reach",
  grow: 1,
  x,
  y: 300,
  autoCurl: true,
  curl: 0,
  angle: 20,
  length: 60,
  bend: 30,
  prop: "none",
  layer: "front"
})

export const defaultState: PlaygroundState = {
  look: defaultBotMascotConfig,
  animation: "idle",
  time: 0,
  playing: true,
  speed: 1,
  loop: true,
  showGaze: false,
  fps: 60,
  backdrop: "light",
  rig: {
    on: false,
    left: restingArm(80),
    right: restingArm(420),
    overlays: { silhouette: false, edges: false, outline: false, points: false }
  },
  view: "outfit",
  theme: "light",
  follow: true,
  move: "idle"
}

export const frameOf = (state: PlaygroundState): number => Math.floor(state.time * state.fps + 1e-6)

export const withArm = (
  rig: RigControls,
  side: ArmSide,
  patch: Partial<ArmControls>
): RigControls => ({ ...rig, [side]: { ...rig[side], ...patch } })
