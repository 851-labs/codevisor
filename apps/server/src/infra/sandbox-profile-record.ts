import type { Sandbox, SandboxProfile } from "@codevisor/api"

import { HttpFailure } from "../server-context.js"
import type { SandboxConnection } from "./sandbox-connections.js"

type ProfileLink = Pick<Sandbox, "provider" | "profileId" | "profileName" | "accountId">

export const connectionOf = (owner: Pick<Sandbox, "provider" | "accountId">): SandboxConnection =>
  owner.accountId === undefined
    ? { provider: owner.provider }
    : { provider: owner.provider, accountId: owner.accountId }

export const profileRecordFields = (profile: SandboxProfile): ProfileLink => ({
  provider: profile.provider,
  profileId: profile.id,
  profileName: profile.name,
  ...(profile.accountId === undefined ? {} : { accountId: profile.accountId })
})

export const profileOrMissing = async (
  deps: {
    readonly profiles: { readonly get: (id: string) => Promise<SandboxProfile | undefined> }
  },
  profileId: string
): Promise<SandboxProfile> => {
  const profile = await deps.profiles.get(profileId)
  if (profile === undefined) throw new HttpFailure(404, `No sandbox profile ${profileId}`)
  return profile
}

type OptionalLink =
  | "projectName"
  | "repoUrl"
  | "profileId"
  | "profileName"
  | "accountId"
  | "workspaceId"
  | "harnessId"

export const OPTIONAL_LINKS: ReadonlyArray<OptionalLink> = [
  "projectName",
  "repoUrl",
  "profileId",
  "profileName",
  "accountId"
]

export const optionalLinks = <Key extends OptionalLink>(
  machine: Sandbox,
  keys: ReadonlyArray<Key>
): Partial<Pick<Sandbox, Key>> => {
  const links: { -readonly [Link in Key]?: string } = {}
  for (const key of keys) {
    const value = machine[key]
    if (value !== undefined) links[key] = value
  }
  return links
}
