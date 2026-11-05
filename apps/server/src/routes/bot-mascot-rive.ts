import { readFile } from "node:fs/promises"
import { fileURLToPath } from "node:url"

import {
  riveValues,
  type BotMascotConfig,
  type MakeupChoice,
  type RiveValues
} from "@codevisor/bot-mascot"

import type { MascotArt } from "./bot-mascot-art.js"

const noMakeup: MakeupChoice = { blush: false, freckles: false, lashes: false }
const riveType = "application/octet-stream"

let riveFile: Promise<MascotArt> | null = null

export const mascotRiveFile = (): Promise<MascotArt> => {
  riveFile ??= readRiveFile()
  return riveFile
}

export const mascotRiveValues = (config: BotMascotConfig): RiveValues =>
  riveValues({ ...config, makeup: noMakeup })

async function readRiveFile(): Promise<MascotArt> {
  const path = fileURLToPath(import.meta.resolve("@codevisor/bot-mascot/rive/mascot.riv"))
  return { bytes: await readFile(path), contentType: riveType }
}
