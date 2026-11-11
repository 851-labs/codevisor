export { renderBotMascotSvg, CALLING_STILL, type StaticRenderOptions } from "./render-static.js"
export {
  defaultBotMascotConfig,
  dressed,
  portraitViewBox,
  randomBotMascotConfig,
  resolveConfig,
  type BotMascotConfig,
  type Random,
  type ResolvedBotMascotConfig,
  type SwatchChoice
} from "./config.js"
export {
  botMascotColors,
  botMascotEyewear,
  botMascotHats,
  botMascotMakeup,
  botMascotMoodOptions,
  botMascotOutfits,
  botMascotSwatches,
  swatchesFor,
  type BotMascotColor,
  type BotMascotEyewear,
  type BotMascotHat,
  type BotMascotMakeup,
  type BotMascotMood,
  type BotMascotOutfit,
  type BotMascotSwatch,
  type ColorOption,
  type ItemOption,
  type MoodOption,
  type SwatchOption
} from "./options.js"
export {
  botMascotLoops,
  FIGURE_VIEW_BOX,
  renderBotMascotLoopFrame,
  type BotMascotLoop,
  type LoopFrameOptions,
  type LoopTiming
} from "./render-loop.js"
export { BotMascotPlayer, type BotMascotPlayerOptions } from "./player.js"
export {
  botMascotRoute,
  botMascotSegmentIds,
  botMascotSegments,
  botMascotSequence,
  canFollow,
  loopOf,
  soloFrame,
  type BotMascotRequest,
  type BotMascotSegment,
  type BotMascotSequence,
  type BotMascotState,
  type SegmentFrame,
  type SegmentInfo,
  type SequenceStep
} from "./segments.js"
export { renderBotMascotSegmentFrame, type SegmentFrameOptions } from "./render-segment.js"
export {
  isRiveColor,
  RIVE_ARTBOARD,
  RIVE_STATE_MACHINE,
  riveColorTable,
  riveValues,
  type RiveColorTable,
  type RiveValue,
  type RiveValues
} from "./rive/values.js"
export {
  GAZE_RANGE,
  gazeOrigin,
  lookingAt,
  type BotMascotGaze,
  type GazeRange
} from "./gaze/gaze.js"
export { GAZE_EASING, gazeFollower, GazeFollower, type GazeEasing } from "./gaze/gaze-follower.js"

export type * from "./pose.js"
export { botMascotColorRotation, palette, type Palette } from "./color/palette.js"
export {
  colorOf,
  hatTint,
  mix,
  namedColors,
  swatches,
  wearTint,
  type SwatchSet
} from "./color/colors.js"
export {
  bodyOf,
  officialBody,
  officialBodyZones,
  originalBodyZones,
  type Body,
  type BodyZones
} from "./body/zones.js"
export { bodyOutline, deform, headTf, isRest } from "./body/rig.js"
export {
  renderContext,
  withHands,
  type HandDrawer,
  type RenderContext,
  type RenderContextOptions
} from "./render/context.js"
export {
  frameParts,
  LIGHT,
  renderFrame as renderBotMascotFrame,
  type Backdrop,
  type FrameOptions
} from "./render/frame.js"
export { mountBotMascot, type MountedDraw, type MountHost, type MountNode } from "./render/mount.js"
export { blendPoses, botMascotMoods, idleAt, isBotMascotMood, type Mood } from "./moods/moods.js"
export { hatItems, hatSvg, type HatItem, type HatKind } from "./hats/hats.js"
export { hatRider, type HatMotion, type HatRider } from "./hats/hat-rider.js"
export { eyewearItems, type EyewearItem, type EyewearKind } from "./face/eyewear.js"
export { makeupItems } from "./face/makeup.js"
export { outfitItems, type Dangle, type OutfitItem, type OutfitKind } from "./outfits/outfits.js"
export { dangle, type DanglingEnd } from "./drapes/dangle.js"
export {
  DrapeSwings,
  redrape,
  type DrapeArm,
  type DrapedFrame,
  type Redraped
} from "./drapes/redrape.js"
export {
  floatingHand,
  handPoses,
  handPop,
  type HandOptions,
  type HandPose
} from "./effects/hands.js"
export {
  armsFrameState,
  IDLE_WORKING_TIMES,
  renderIdleWorking,
  type ArmsFrameState,
  type IdleWorkingOptions,
  type WorkingTimes
} from "./animations/idle-working.js"
export { flipState, pageGrip, type FlipState } from "./animations/working-flip.js"
export {
  CALLING_SWAP_LOOP,
  callingSwapPose,
  originalCalling,
  renderCallingSwap,
  type CallingSwapOptions
} from "./animations/calling-swap.js"
export { CALLING_EXIT } from "./animations/calling-exit.js"
export {
  poseArm,
  propMatrix,
  gripWay,
  type ArmPoseOptions,
  type ArmProp,
  type Matrix,
  type PosedArm
} from "./arms/arm-pose.js"
export {
  compose as composeArms,
  type ArmLayer,
  type ComposeItem,
  type ComposeOptions,
  type Composed
} from "./arms/compose.js"
export { drawRig, phoneProp, type RigDrawOptions } from "./arms/rig-draw.js"
export { drawArm, type ArmDrawing } from "./arms/draw-arm.js"
export { armEdges } from "./arms/arm-edges.js"
export { reach, bendOf, upCurl } from "./arms/reach.js"
export {
  armOrigin,
  armStart,
  blendArms,
  growth,
  restArm,
  emerging,
  shoulder,
  spinePoints,
  spineTip,
  ARM_LENGTH,
  type RigArm,
  type Torso
} from "./arms/rig-arm.js"
export { outlinePoly, signedDistance } from "./arms/outline-poly.js"
export {
  aimCurl,
  BOT_MASCOT_ARM,
  curvedFlipper,
  edgeX,
  restingArm,
  FLIPPER_LENGTH,
  FLIPPER_REST,
  type FlipperArm,
  type FlipperShape
} from "./arms/flipper.js"
export { flipperOutline } from "./arms/flipper-outline.js"
export { drawFlippersInBody, drawFlippersOver } from "./arms/flipper-draw.js"
