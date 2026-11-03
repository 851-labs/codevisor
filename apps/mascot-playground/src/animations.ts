import {
  botMascotMoodOptions,
  botMascotMoods,
  CALLING_EXIT,
  CALLING_STILL,
  callingSwapPose,
  dressed,
  IDLE_WORKING_TIMES,
  idleAt,
  renderBotMascotFrame,
  renderCallingSwap,
  renderContext,
  renderIdleWorking,
  type BotMascotMood,
  type BotMascotPose,
  type MoodOption,
  type ResolvedBotMascotConfig
} from "@codevisor/bot-mascot"

export interface SceneFrame {
  readonly look: ResolvedBotMascotConfig
  readonly t: number
  readonly viewBox: string
  readonly uid: string
}

export interface Animation {
  readonly id: string
  readonly title: string
  readonly seconds: number
  readonly render: (frame: SceneFrame) => string
  readonly rigPose: (t: number) => BotMascotPose
}

type Renderer = (frame: SceneFrame) => string

const openEndedSeconds = 15

const contextFor = (frame: SceneFrame) => renderContext({ idPrefix: frame.uid })

const armsMode =
  (mode: "idle" | "working"): Renderer =>
  (frame) =>
    renderIdleWorking(contextFor(frame), frame.look.color, frame.t, frame.viewBox, frame.uid, {
      mode,
      edit: dressed(frame.look)
    })

const calling: Renderer = (frame) =>
  renderCallingSwap(contextFor(frame), frame.look.color, frame.t, {
    viewBox: frame.viewBox,
    uid: frame.uid,
    pose: dressed(frame.look)(callingSwapPose(frame.t))
  })

const plainMood =
  (mood: BotMascotMood): Renderer =>
  (frame) =>
    renderBotMascotFrame(
      contextFor(frame),
      frame.look.color,
      dressed(frame.look)(botMascotMoods[mood].pose(frame.t)),
      { viewBox: frame.viewBox, uid: frame.uid }
    )

const moodRenderers: Partial<Record<BotMascotMood, Renderer>> = {
  idle: armsMode("idle"),
  working: armsMode("working"),
  calling
}

const armMoods: ReadonlySet<BotMascotMood> = new Set(["working", "calling"])

const moodRigPose = (mood: BotMascotMood): ((t: number) => BotMascotPose) => {
  if (armMoods.has(mood)) return idleAt
  return (t) => botMascotMoods[mood].pose(t)
}

const moodAnimation = (option: MoodOption): Animation => ({
  id: option.id,
  title: option.title,
  seconds: option.loop ?? openEndedSeconds,
  render: moodRenderers[option.id] ?? plainMood(option.id),
  rigPose: moodRigPose(option.id)
})

const idleToWorking: Animation = {
  id: "idle-working",
  title: "Idle → Working → Idle",
  seconds: IDLE_WORKING_TIMES.end,
  render: (frame) =>
    renderIdleWorking(contextFor(frame), frame.look.color, frame.t, frame.viewBox, frame.uid, {
      edit: dressed(frame.look)
    }),
  rigPose: idleAt
}

const callingExit: Animation = {
  id: "calling-exit",
  title: "Calling hang-up",
  seconds: CALLING_EXIT,
  render: (frame) =>
    renderCallingSwap(contextFor(frame), frame.look.color, CALLING_STILL, {
      viewBox: frame.viewBox,
      uid: frame.uid,
      pose: dressed(frame.look)(callingSwapPose(CALLING_STILL)),
      exit: frame.t
    }),
  rigPose: idleAt
}

export const animations: ReadonlyArray<Animation> = [
  ...botMascotMoodOptions.map(moodAnimation),
  idleToWorking,
  callingExit
]

export const animationById = (id: string): Animation =>
  animations.find((animation) => animation.id === id) ?? animations[0]!
