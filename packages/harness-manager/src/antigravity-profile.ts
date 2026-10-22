import { lstat, mkdir, readdir, readFile, rename, rm, symlink, writeFile } from "node:fs/promises"
import { join } from "node:path"

import { AGY_GEMINI_DIR_ENV } from "@codevisor/adapter-antigravity"

import { recordOrEmpty } from "./json-values.js"

export const ANTIGRAVITY_HARNESS_ID = "antigravity"

export const antigravityGeminiDir = (profile: string): string => join(profile, "gemini")

const PRIVATE = /token|cred|auth|oauth|secret|keyring/i

const linkEntries = async (
  from: string,
  to: string,
  include: (name: string) => boolean
): Promise<void> => {
  let names: Array<string>
  try {
    names = await readdir(from)
  } catch {
    return
  }
  await mkdir(to, { recursive: true, mode: 0o700 })
  for (const name of names) {
    if (name.startsWith(".") || PRIVATE.test(name) || !include(name)) continue
    const target = join(to, name)
    const exists = await lstat(target).then(
      () => true,
      () => false
    )
    if (!exists) await symlink(join(from, name), target).catch(() => undefined)
  }
}

const settingsDocument = async (path: string): Promise<Record<string, unknown>> => {
  try {
    return recordOrEmpty(JSON.parse(await readFile(path, "utf8")))
  } catch {
    return {}
  }
}

export const prepareAntigravityProfile = async (
  profile: string,
  env: NodeJS.ProcessEnv,
  apiKey: string | undefined
): Promise<Record<string, string>> => {
  const root = antigravityGeminiDir(profile)
  const cli = join(root, "antigravity-cli")
  await mkdir(cli, { recursive: true, mode: 0o700 })
  const user = env.HOME?.trim()
  const own = user ? join(user, ".gemini") : undefined
  if (own !== undefined) {
    await linkEntries(join(own, "config"), join(root, "config"), (name) => name !== "projects")
    await linkEntries(own, root, (name) => /^(AGENTS|GEMINI)\.md$/.test(name))
  }
  const settings = join(cli, "settings.json")
  const userSettings = own === undefined ? undefined : join(own, "antigravity-cli", "settings.json")
  if (apiKey !== undefined) {
    let userDocument: Record<string, unknown> = {}
    if (userSettings !== undefined) userDocument = await settingsDocument(userSettings)
    const document = { ...userDocument, modelProvider: "gemini" }
    const temporary = `${settings}.${process.pid}.tmp`
    await writeFile(temporary, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600 })
    await rm(settings, { force: true })
    await rename(temporary, settings)
  } else if (userSettings !== undefined && (await lstat(userSettings).catch(() => undefined))) {
    const current = await lstat(settings).catch(() => undefined)
    if (current?.isFile() === true) await rm(settings, { force: true })
    if (current === undefined || current.isFile())
      await symlink(userSettings, settings).catch(() => undefined)
  }
  return {
    [AGY_GEMINI_DIR_ENV]: root,
    ...(apiKey === undefined ? {} : { GEMINI_API_KEY: apiKey })
  }
}
