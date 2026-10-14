import { createHash } from "node:crypto"
import { chmod, mkdir, readFile, rename, rm, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"

import { ANTIGRAVITY_HARNESS_ID, antigravityGeminiDir } from "./antigravity-profile.js"
import type { SharedTokenBundle } from "./shared-credential-types.js"

export const antigravityAuthPath = (profile: string): string =>
  join(antigravityGeminiDir(profile), "antigravity-cli", "antigravity-oauth-token")

const object = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
const string = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

const idTokenEmail = (idToken: string | undefined): string | undefined => {
  const payload = idToken?.split(".")[1]
  if (payload === undefined) return undefined
  try {
    return string(object(JSON.parse(Buffer.from(payload, "base64url").toString("utf8"))).email)
  } catch {
    return undefined
  }
}

export const parseAntigravityAuth = (
  document: unknown,
  ownership: SharedTokenBundle["ownership"]
): SharedTokenBundle | undefined => {
  const token = object(object(document).token)
  const refreshToken = string(token.refresh_token)
  if (refreshToken === undefined) return undefined
  const email = idTokenEmail(string(object(document).id_token))
  return {
    harnessId: ANTIGRAVITY_HARNESS_ID,
    subject: `google:${createHash("sha256")
      .update(email?.toLowerCase() ?? refreshToken)
      .digest("hex")}`,
    accessToken: refreshToken,
    expiresAt: Number.MAX_SAFE_INTEGER,
    ownership,
    ...(email === undefined ? {} : { email }),
    credential: { document: object(document) }
  }
}

const readDocument = async (path: string): Promise<Record<string, unknown> | undefined> => {
  try {
    return object(JSON.parse(await readFile(path, "utf8")))
  } catch {
    return undefined
  }
}

export const writeAntigravityAuth = async (
  profile: string,
  bundle: SharedTokenBundle
): Promise<void> => {
  const path = antigravityAuthPath(profile)
  const document = object(object(bundle.credential).document)
  const current = await readDocument(path)
  if (
    current !== undefined &&
    string(object(current.token).refresh_token) === string(object(document.token).refresh_token)
  )
    return
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.${process.pid}.tmp`
  await writeFile(temporary, JSON.stringify(document), { mode: 0o600 })
  await chmod(temporary, 0o600)
  await rename(temporary, path)
}

export const removeAntigravityAuth = (profile: string): Promise<void> =>
  rm(antigravityAuthPath(profile), { force: true })
