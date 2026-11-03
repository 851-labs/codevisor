import {
  botMascotSegmentIds,
  botMascotSegments,
  idleAt,
  renderBotMascotSegmentFrame,
  soloFrame,
  type BotMascotGaze,
  type BotMascotPose,
  type BotMascotSegment,
  type ResolvedBotMascotConfig
} from "@codevisor/bot-mascot"

export interface SceneFrame {
  readonly look: ResolvedBotMascotConfig
  readonly t: number
  readonly viewBox: string
  readonly uid: string
  readonly gaze: BotMascotGaze | null
}

export interface Animation {
  readonly id: string
  readonly title: string
  readonly seconds: number
  readonly render: (frame: SceneFrame) => string
  readonly rigPose: (t: number) => BotMascotPose
  readonly gazes: boolean
}

const segmentAnimation = (segment: BotMascotSegment): Animation => ({
  id: segment,
  title: botMascotSegments[segment].title,
  seconds: botMascotSegments[segment].seconds,
  render: (scene) =>
    renderBotMascotSegmentFrame({
      ...scene.look,
      frame: soloFrame(segment, scene.t),
      viewBox: scene.viewBox,
      uid: scene.uid
    }),
  rigPose: idleAt,
  gazes: false
})

const idleLookingAtCursor: Animation = {
  id: "idle-gaze",
  title: "Idle (looks at cursor)",
  seconds: botMascotSegments.idle.seconds,
  render: (scene) =>
    renderBotMascotSegmentFrame({
      ...scene.look,
      frame: soloFrame("idle", scene.t),
      gaze: scene.gaze,
      viewBox: scene.viewBox,
      uid: scene.uid
    }),
  rigPose: idleAt,
  gazes: true
}

const [idle, ...parts] = botMascotSegmentIds.map(segmentAnimation)

export const animations: ReadonlyArray<Animation> = [idle!, idleLookingAtCursor, ...parts]

export const animationById = (id: string): Animation =>
  animations.find((animation) => animation.id === id) ?? animations[0]!
