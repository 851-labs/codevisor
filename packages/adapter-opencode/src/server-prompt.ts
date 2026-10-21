import { randomInt } from "node:crypto"
import { access, constants } from "node:fs/promises"
import { pathToFileURL } from "node:url"

import type { PromptInput } from "@codevisor/agent-runtime"

import type { Catalog } from "./catalog.js"

export type Submission =
  | { readonly kind: "prompt"; readonly body: Readonly<Record<string, unknown>> }
  | { readonly kind: "command"; readonly body: Readonly<Record<string, unknown>> }
  | { readonly kind: "compact" }

export type Readable = (path: string) => Promise<boolean>

const ID_CHARS = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

export const makeMessageIds = () => {
  let lastTimestamp = 0
  let counter = 0
  return (now = Date.now()): string => {
    counter = now === lastTimestamp ? counter + 1 : 1
    lastTimestamp = now
    const time = (BigInt(now) * 0x1000n + BigInt(counter)).toString(16).padStart(12, "0").slice(-12)
    const random = Array.from({ length: 14 }, () => ID_CHARS[randomInt(ID_CHARS.length)]).join("")
    return `msg_${time}${random}`
  }
}

export const isReadable: Readable = (path) =>
  access(path, constants.R_OK).then(
    () => true,
    () => false
  )

interface Attachments {
  readonly files: ReadonlyArray<{ readonly uri: string; readonly name: string }>
  readonly unreadable: ReadonlyArray<string>
}

const attachments = async (input: PromptInput, readable: Readable): Promise<Attachments> => {
  const files: Array<{ readonly uri: string; readonly name: string }> = []
  const unreadable: Array<string> = []
  for (const attachment of input.attachments ?? []) {
    if (await readable(attachment.path)) {
      files.push({ uri: pathToFileURL(attachment.path).href, name: attachment.name })
    } else if (attachment.inline !== undefined) {
      files.push({
        uri: `data:${attachment.inline.mimeType};base64,${attachment.inline.data.toString("base64")}`,
        name: attachment.name
      })
    } else {
      unreadable.push(`[${attachment.name}](${pathToFileURL(attachment.path).href})`)
    }
  }
  return { files, unreadable }
}

const slash = (text: string): { readonly name: string; readonly args: string } | undefined => {
  const value = text.trim()
  if (!value.startsWith("/")) return undefined
  const [name, ...rest] = value.slice(1).split(/\s+/)
  return name === undefined || name === "" ? undefined : { name, args: rest.join(" ").trim() }
}

export const promptBody = async (
  input: PromptInput,
  readable: Readable
): Promise<Readonly<Record<string, unknown>>> => {
  const { files, unreadable } = await attachments(input, readable)
  return {
    text: [input.text, ...unreadable].filter((part) => part !== "").join("\n"),
    ...(files.length === 0 ? {} : { files })
  }
}

export const prepareSubmission = async (
  input: PromptInput,
  catalog: Catalog,
  readable: Readable
): Promise<Submission> => {
  const body = await promptBody(input, readable)
  const command = slash(input.text)
  if (command?.name === "compact" && !catalog.commands.includes("compact"))
    return { kind: "compact" }
  if (command !== undefined && catalog.commands.includes(command.name))
    return { kind: "command", body: { ...body, name: command.name, text: command.args } }
  const skill = catalog.skills.skills.find(
    (candidate) => command !== undefined && candidate.invocation === `/${command.name}`
  )
  return {
    kind: "prompt",
    body: skill === undefined ? body : { ...body, skills: [{ id: skill.name }] }
  }
}
