import { createHash } from "node:crypto"
import { readFile } from "node:fs/promises"
import { fileURLToPath } from "node:url"

import {
  riveValues,
  type BotMascotConfig,
  type MakeupChoice,
  type RiveValues
} from "@codevisor/bot-mascot"

import type { MascotArt } from "./bot-mascot-art.js"

export interface RiveFile extends MascotArt {
  readonly etag: string
}

const noMakeup: MakeupChoice = { blush: false, freckles: false, lashes: false }
const riveType = "application/octet-stream"

let riveFile: Promise<RiveFile> | null = null

export const mascotRiveFile = (): Promise<RiveFile> => {
  riveFile ??= readRiveFile()
  return riveFile
}

export const mascotRiveValues = (config: BotMascotConfig): RiveValues =>
  riveValues({ ...config, makeup: noMakeup })

async function readRiveFile(): Promise<RiveFile> {
  const path = fileURLToPath(import.meta.resolve("@codevisor/bot-mascot/rive/mascot.riv"))
  const bytes = await readFile(path)
  return { bytes, contentType: riveType, etag: contentTag(bytes) }
}

const contentTag = (bytes: Buffer): string =>
  `"${createHash("sha256").update(bytes).digest("base64url")}"`
