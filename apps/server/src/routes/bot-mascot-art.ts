import {
  botMascotLoops,
  FIGURE_VIEW_BOX,
  portraitViewBox,
  renderBotMascotLoopFrame,
  renderBotMascotSvg,
  type BotMascotConfig,
  type BotMascotLoop,
  type MakeupChoice
} from "@codevisor/bot-mascot"
import sharp from "sharp"

export type MascotFraming = "portrait" | "figure"

export interface MascotArt {
  readonly bytes: Buffer
  readonly contentType: string
}

export const mascotFramings: ReadonlyArray<MascotFraming> = ["portrait", "figure"]
export const mascotLoops: ReadonlyArray<BotMascotLoop> = ["idle", "working"]

const stillPixels = 384
const loopPixels = 112
const loopFramesPerSecond = 12
const loopQuality = 90
const cachedLoops = 24
const noMakeup: MakeupChoice = { blush: false, freckles: false, lashes: false }
const loops = new Map<string, Promise<MascotArt>>()

export const renderMascotStill = async (
  config: BotMascotConfig,
  framing: MascotFraming
): Promise<MascotArt> => {
  const svg = renderBotMascotSvg({
    ...config,
    makeup: noMakeup,
    viewBox: viewBoxFor(config, framing),
    size: stillPixels
  })
  const bytes = await sharp(Buffer.from(svg)).png({ compressionLevel: 9 }).toBuffer()
  return { bytes, contentType: "image/png" }
}

export const renderMascotLoop = (
  config: BotMascotConfig,
  loop: BotMascotLoop
): Promise<MascotArt> => {
  const key = JSON.stringify([
    config.color,
    config.hat,
    config.hatColor,
    config.eyewear,
    config.eyewearColor,
    loop
  ])
  const cached = loops.get(key) ?? encodeLoop(config, loop)
  remember(key, cached)
  return cached
}

const viewBoxes: Readonly<Record<MascotFraming, (config: BotMascotConfig) => string>> = {
  portrait: (config) => portraitViewBox(config.hat),
  figure: () => FIGURE_VIEW_BOX
}

const viewBoxFor = (config: BotMascotConfig, framing: MascotFraming): string =>
  viewBoxes[framing](config)

const remember = (key: string, art: Promise<MascotArt>): void => {
  loops.delete(key)
  loops.set(key, art)
  art.catch(() => loops.delete(key))
  if (loops.size > cachedLoops) loops.delete(loops.keys().next().value!)
}

const encodeLoop = async (config: BotMascotConfig, loop: BotMascotLoop): Promise<MascotArt> => {
  const frames = await loopFrames(config, loop)
  const bytes = await sharp(frames, { join: { animated: true } })
    .webp({
      quality: loopQuality,
      alphaQuality: 100,
      loop: 0,
      delay: frames.map(() => Math.round(1000 / loopFramesPerSecond))
    })
    .toBuffer()
  return { bytes, contentType: "image/webp" }
}

const loopFrames = async (config: BotMascotConfig, loop: BotMascotLoop): Promise<Array<Buffer>> => {
  const count = Math.round(botMascotLoops[loop].seconds * loopFramesPerSecond)
  const frames: Array<Buffer> = []
  for (let index = 0; index < count; index++) {
    frames.push(await loopFrame(config, loop, index / loopFramesPerSecond))
  }
  return frames
}

const loopFrame = (config: BotMascotConfig, loop: BotMascotLoop, t: number): Promise<Buffer> => {
  const svg = renderBotMascotLoopFrame({
    ...config,
    makeup: noMakeup,
    loop,
    t,
    viewBox: FIGURE_VIEW_BOX,
    size: loopPixels
  })
  return sharp(Buffer.from(svg)).png().toBuffer()
}
