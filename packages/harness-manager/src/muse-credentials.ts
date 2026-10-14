import { createHash } from "node:crypto"
import { chmod, lstat, mkdir, readdir, rename, rm, symlink, writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"

import type { SharedTokenBundle } from "./shared-credential-types.js"

export const MUSE_HARNESS_ID = "muse-code"

const object = (value: unknown): Record<string, unknown> =>
  typeof value === "object" && value !== null && !Array.isArray(value)
    ? (value as Record<string, unknown>)
    : {}
const string = (value: unknown): string | undefined =>
  typeof value === "string" && value.length > 0 ? value : undefined

export const museConfigHome = (profile: string): string => join(profile, "config")
export const museAuthPath = (profile: string): string =>
  join(museConfigHome(profile), "muse", "auth.json")

export const museProfileEnv = (profile: string): Record<string, string> => ({
  XDG_CONFIG_HOME: museConfigHome(profile),
  TBH_CREDENTIAL_BACKEND: "file"
})

export const parseMuseAuth = (
  document: unknown,
  ownership: SharedTokenBundle["ownership"]
): SharedTokenBundle | undefined => {
  const meta = object(object(object(document).providers).meta)
  const accessToken = string(meta.access_token) ?? string(meta.api_key)
  if (accessToken === undefined) return undefined
  const email = string(meta.user_email)
  return {
    harnessId: MUSE_HARNESS_ID,
    subject: `meta:${createHash("sha256")
      .update(email?.toLowerCase() ?? accessToken)
      .digest("hex")}`,
    accessToken,
    expiresAt: Number.MAX_SAFE_INTEGER,
    ownership,
    ...(email === undefined ? {} : { email }),
    credential: { meta }
  }
}

export const writeMuseAuth = async (profile: string, bundle: SharedTokenBundle): Promise<void> => {
  const path = museAuthPath(profile)
  await mkdir(dirname(path), { recursive: true, mode: 0o700 })
  const temporary = `${path}.${process.pid}.tmp`
  const document = { schema_version: 1, providers: { meta: object(bundle.credential?.meta) } }
  await writeFile(temporary, `${JSON.stringify(document, null, 2)}\n`, { mode: 0o600 })
  await chmod(temporary, 0o600)
  await rename(temporary, path)
}

export const removeMuseAuth = (profile: string): Promise<void> =>
  rm(museAuthPath(profile), { force: true })

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
  for (const name of names) {
    if (!include(name)) continue
    const target = join(to, name)
    const exists = await lstat(target).then(
      () => true,
      () => false
    )
    if (!exists) await symlink(join(from, name), target).catch(() => undefined)
  }
}

export const linkMuseConfigHome = async (
  profile: string,
  env: NodeJS.ProcessEnv
): Promise<void> => {
  const user = env.HOME?.trim()
  const own = env.XDG_CONFIG_HOME?.trim() || (user ? join(user, ".config") : undefined)
  const home = museConfigHome(profile)
  await mkdir(join(home, "muse"), { recursive: true, mode: 0o700 })
  if (own === undefined) return
  await linkEntries(own, home, (name) => name !== "muse")
  await linkEntries(
    join(own, "muse"),
    join(home, "muse"),
    (name) => name !== "auth.json" && !name.startsWith(".")
  )
}
