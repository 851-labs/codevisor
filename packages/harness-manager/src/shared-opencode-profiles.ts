import { createHash } from "node:crypto"
import { join } from "node:path"

import type {
  CodevisorDatabaseService,
  HarnessAccountRecord,
  SaveHarnessAccountRequest
} from "@codevisor/db"

import {
  atomicWriteJson,
  readJsonFile,
  withFileLock,
  type CredentialSource
} from "./credential-ferry.js"
import { run } from "./harness-auth-support.js"
import { isRecord } from "./json-values.js"

interface Profile {
  id: string
  label: string
}
interface Profiles {
  profiles: Profile[]
  activeProfileId: string
}
const empty = (): Profiles => ({ profiles: [], activeProfileId: "default" })

const parseProfiles = (value: unknown): Profiles => {
  if (!isRecord(value) || !Array.isArray(value.profiles) || !("activeProfileId" in value)) {
    throw new Error("Invalid shared OpenCode profiles")
  }
  const profiles: Profile[] = []
  const ids = new Set<string>()
  for (const profile of value.profiles) {
    if (
      !isRecord(profile) ||
      typeof profile.id !== "string" ||
      !/^shared-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(profile.id) ||
      typeof profile.label !== "string" ||
      !profile.label.trim() ||
      ids.has(profile.id)
    ) {
      throw new Error("Invalid shared OpenCode profile")
    }
    ids.add(profile.id)
    profiles.push({ id: profile.id, label: profile.label })
  }
  const activeProfileId = value.activeProfileId
  if (
    activeProfileId !== "default" &&
    (typeof activeProfileId !== "string" || !ids.has(activeProfileId))
  )
    throw new Error("Invalid shared OpenCode selection")
  return { profiles, activeProfileId }
}

const fingerprint = (value: unknown): string =>
  createHash("sha256").update(JSON.stringify(value)).digest("hex")

export const sharedProfileCredentialSource = (id: string, directory: string): CredentialSource => {
  const path = join(directory, "data", "opencode", "auth.json")
  const baselinePath = join(directory, ".shared-credentials.json")
  return {
    id: `opencode-profile:${id}`,
    tombstoneOnAbsence: false,
    read: async () => undefined,
    apply: async (content) => {
      const incoming: unknown = JSON.parse(content)
      if (
        !isRecord(incoming) ||
        Object.values(incoming).some(
          (value) => !isRecord(value) || (value.type !== "api" && value.type !== "wellknown")
        )
      ) {
        throw new Error("Shared profiles support static provider credentials only")
      }
      await withFileLock(path, async () => {
        const current = (await readJsonFile(path))!
        const baseline = (await readJsonFile(baselinePath)) ?? {}
        const next = { ...current }
        const hashes = { ...baseline }
        for (const provider of new Set([
          ...Object.keys(current),
          ...Object.keys(baseline),
          ...Object.keys(incoming)
        ])) {
          const currentHash = provider in current ? fingerprint(current[provider]) : undefined
          if (currentHash !== baseline[provider]) continue
          if (provider in incoming) {
            next[provider] = incoming[provider]
            hashes[provider] = fingerprint(incoming[provider])
          } else {
            delete next[provider]
            delete hashes[provider]
          }
        }
        await atomicWriteJson(path, next)
        await atomicWriteJson(baselinePath, hashes)
      })
    }
  }
}

export interface SharedProfileDeps {
  readonly db: CodevisorDatabaseService
  readonly dataDir: string
  readonly removeAccount: (id: string) => Promise<void>
}

export const reconcileSharedOpenCodeProfiles = async (
  deps: SharedProfileDeps,
  content?: string
): Promise<ReadonlyArray<CredentialSource>> => {
  const desired = desiredProfiles(content)
  const markerPath = sharedMarkerPath(deps.dataDir)
  const previous = recordedProfiles(await readJsonFile(markerPath))
  const accounts = await run(deps.db.listHarnessAccounts("opencode"))
  let defaultAccount = accounts.find(isDefaultAccount)
  if (defaultAccount === undefined)
    defaultAccount = await run(deps.db.saveHarnessAccount(defaultAccountRequest()))

  const sources: CredentialSource[] = []
  const present = new Set<string>(["default"])
  for (const profile of desired.profiles) {
    const account = await run(deps.db.getHarnessAccount(profile.id))
    const prior = priorProfile(previous, profile)
    if (removedLocally(account, prior)) continue
    if (conflictsWithProfile(account, profile))
      throw new Error("Shared profile conflicts with an existing account")

    const write = writeProfileAccount(deps, account, profile, prior)
    if (write !== undefined) await write
    present.add(profile.id)
    sources.push(profileCredentialSource(deps.dataDir, profile))
  }

  for (const profile of previous.profiles) {
    if (removedUpstream(profile, desired, accounts)) await deps.removeAccount(profile.id)
  }

  const selectedId = selectedProfileId(accounts)
  if (adoptsSharedSelection(present, desired, previous, selectedId)) {
    await run(deps.db.setActiveHarnessAccount("opencode", activeAccountId(desired, defaultAccount)))
  }
  await atomicWriteJson(markerPath, { ...desired })
  return sources
}

const profilesDirectory = "harness-profiles"

const desiredProfiles = (content: string | undefined): Profiles => {
  if (content === undefined) return empty()
  return parseProfiles(JSON.parse(content))
}

const recordedProfiles = (marker: Record<string, unknown> | undefined): Profiles => {
  if (marker === undefined) return empty()
  return parseProfiles(marker)
}

const sharedMarkerPath = (dataDir: string): string =>
  join(dataDir, profilesDirectory, ".shared-opencode.json")

const profileCredentialSource = (dataDir: string, profile: Profile): CredentialSource =>
  sharedProfileCredentialSource(
    profile.id,
    join(dataDir, profilesDirectory, "opencode", profile.id)
  )

const isDefaultAccount = (account: HarnessAccountRecord): boolean =>
  account.profileKind === "default"

const defaultAccountRequest = (): SaveHarnessAccountRequest => ({
  harnessId: "opencode",
  profileKind: "default",
  label: "Default Profile",
  authState: "unauthenticated",
  canLogin: true,
  canLogout: false
})

const managedAccountRequest = (profile: Profile): SaveHarnessAccountRequest => ({
  id: profile.id,
  harnessId: "opencode",
  profileKind: "managed",
  profileKey: profile.id,
  label: profile.label,
  authState: "unauthenticated",
  canLogin: true,
  canLogout: false
})

const priorProfile = (previous: Profiles, profile: Profile): Profile | undefined =>
  previous.profiles.find((item) => item.id === profile.id)

const removedLocally = (
  account: HarnessAccountRecord | undefined,
  prior: Profile | undefined
): boolean => account === undefined && prior !== undefined

const conflictsWithProfile = (
  account: HarnessAccountRecord | undefined,
  profile: Profile
): boolean => account !== undefined && foreignAccount(account, profile)

const foreignAccount = (account: HarnessAccountRecord, profile: Profile): boolean =>
  account.harnessId !== "opencode" ||
  account.profileKind !== "managed" ||
  account.profileKey !== profile.id

const writeProfileAccount = (
  deps: SharedProfileDeps,
  account: HarnessAccountRecord | undefined,
  profile: Profile,
  prior: Profile | undefined
): Promise<HarnessAccountRecord> | undefined => {
  if (account === undefined) return run(deps.db.saveHarnessAccount(managedAccountRequest(profile)))
  if (takesSharedLabel(account, profile, prior)) {
    return run(
      deps.db.updateHarnessAccountAuth(account.id, {
        label: profile.label,
        authState: account.authState
      })
    )
  }
  return undefined
}

const takesSharedLabel = (
  account: HarnessAccountRecord,
  profile: Profile,
  prior: Profile | undefined
): boolean =>
  account.label !== profile.label && (prior === undefined || account.label === prior.label)

const removedUpstream = (
  profile: Profile,
  desired: Profiles,
  accounts: ReadonlyArray<HarnessAccountRecord>
): boolean =>
  !hasProfile(desired.profiles, profile.id) && accounts.some((account) => account.id === profile.id)

const selectedProfileId = (accounts: ReadonlyArray<HarnessAccountRecord>): string => {
  const selected = accounts.find((account) => account.isActive)
  if (selected?.profileKind === "default") return "default"
  if (selected === undefined) return "default"
  return selected.id
}

const adoptsSharedSelection = (
  present: ReadonlySet<string>,
  desired: Profiles,
  previous: Profiles,
  selectedId: string
): boolean =>
  present.has(desired.activeProfileId) && followsSharedSelection(selectedId, previous, desired)

const followsSharedSelection = (
  selectedId: string,
  previous: Profiles,
  desired: Profiles
): boolean =>
  selectedId === previous.activeProfileId ||
  (hasProfile(previous.profiles, selectedId) && !hasProfile(desired.profiles, selectedId))

const hasProfile = (profiles: ReadonlyArray<Profile>, id: string): boolean =>
  profiles.some((profile) => profile.id === id)

const activeAccountId = (desired: Profiles, defaultAccount: HarnessAccountRecord): string =>
  desired.activeProfileId === "default" ? defaultAccount.id : desired.activeProfileId
