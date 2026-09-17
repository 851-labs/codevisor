import { createHash } from "node:crypto"
import { join } from "node:path"

import type { CodevisorDatabaseService } from "@codevisor/db"

import {
  atomicWriteJson,
  readJsonFile,
  withFileLock,
  type CredentialSource
} from "./credential-ferry.js"
import { run } from "./harness-auth-support.js"

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
  if (
    typeof value !== "object" ||
    value === null ||
    !("profiles" in value) ||
    !Array.isArray(value.profiles) ||
    !("activeProfileId" in value)
  ) {
    throw new Error("Invalid shared OpenCode profiles")
  }
  const ids = new Set<string>()
  for (const profile of value.profiles) {
    if (
      typeof profile !== "object" ||
      profile === null ||
      typeof profile.id !== "string" ||
      !/^shared-[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(profile.id) ||
      typeof profile.label !== "string" ||
      !profile.label.trim() ||
      ids.has(profile.id)
    ) {
      throw new Error("Invalid shared OpenCode profile")
    }
    ids.add(profile.id)
  }
  if (value.activeProfileId !== "default" && !ids.has(String(value.activeProfileId)))
    throw new Error("Invalid shared OpenCode selection")
  return value as Profiles
}

const fingerprint = (value: unknown): string =>
  createHash("sha256").update(JSON.stringify(value)).digest("hex")

/// Shared profiles are applied in one direction. A local edit that differs
/// from the last applied value remains an override, including a removed key.
export const sharedProfileCredentialSource = (id: string, directory: string): CredentialSource => {
  const path = join(directory, "data", "opencode", "auth.json")
  const baselinePath = join(directory, ".shared-credentials.json")
  return {
    id: `opencode-profile:${id}`,
    tombstoneOnAbsence: false,
    read: async () => undefined,
    apply: async (content) => {
      const incoming = JSON.parse(content) as Record<string, unknown>
      if (
        typeof incoming !== "object" ||
        incoming === null ||
        Array.isArray(incoming) ||
        Object.values(incoming).some(
          (value) =>
            typeof value !== "object" ||
            value === null ||
            !("type" in value) ||
            (value.type !== "api" && value.type !== "wellknown")
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

export const reconcileSharedOpenCodeProfiles = async (
  deps: {
    readonly db: CodevisorDatabaseService
    readonly dataDir: string
    readonly removeAccount: (id: string) => Promise<void>
  },
  content?: string
): Promise<ReadonlyArray<CredentialSource>> => {
  const desired = content === undefined ? empty() : parseProfiles(JSON.parse(content))
  const markerPath = join(deps.dataDir, "harness-profiles", ".shared-opencode.json")
  const marker = await readJsonFile(markerPath)
  const previous = marker === undefined ? empty() : parseProfiles(marker)
  const accounts = await run(deps.db.listHarnessAccounts("opencode"))
  let defaultAccount = accounts.find((account) => account.profileKind === "default")
  if (defaultAccount === undefined) {
    defaultAccount = await run(
      deps.db.saveHarnessAccount({
        harnessId: "opencode",
        profileKind: "default",
        label: "Default Profile",
        authState: "unauthenticated",
        canLogin: true,
        canLogout: false
      })
    )
  }
  const sources: CredentialSource[] = []
  const present = new Set<string>(["default"])
  for (const profile of desired.profiles) {
    const account = await run(deps.db.getHarnessAccount(profile.id))
    const prior = previous.profiles.find((item) => item.id === profile.id)
    if (account === undefined && prior !== undefined) continue // Removed on this machine.
    if (
      account !== undefined &&
      (account.harnessId !== "opencode" ||
        account.profileKind !== "managed" ||
        account.profileKey !== profile.id)
    )
      throw new Error("Shared profile conflicts with an existing account")
    if (account === undefined) {
      await run(
        deps.db.saveHarnessAccount({
          id: profile.id,
          harnessId: "opencode",
          profileKind: "managed",
          profileKey: profile.id,
          label: profile.label,
          authState: "unauthenticated",
          canLogin: true,
          canLogout: false
        })
      )
    } else if (
      account.label !== profile.label &&
      (prior === undefined || account.label === prior.label)
    ) {
      await run(
        deps.db.updateHarnessAccountAuth(account.id, {
          label: profile.label,
          authState: account.authState
        })
      )
    }
    present.add(profile.id)
    sources.push(
      sharedProfileCredentialSource(
        profile.id,
        join(deps.dataDir, "harness-profiles", "opencode", profile.id)
      )
    )
  }
  for (const profile of previous.profiles) {
    if (
      !desired.profiles.some((item) => item.id === profile.id) &&
      accounts.some((account) => account.id === profile.id)
    )
      await deps.removeAccount(profile.id)
  }
  const selected = accounts.find((account) => account.isActive)
  const selectedId =
    selected?.profileKind === "default" || selected === undefined ? "default" : selected.id
  if (
    present.has(desired.activeProfileId) &&
    (selectedId === previous.activeProfileId ||
      (previous.profiles.some((profile) => profile.id === selectedId) &&
        !desired.profiles.some((profile) => profile.id === selectedId)))
  ) {
    await run(
      deps.db.setActiveHarnessAccount(
        "opencode",
        desired.activeProfileId === "default" ? defaultAccount.id : desired.activeProfileId
      )
    )
  }
  await atomicWriteJson(markerPath, { ...desired })
  return sources
}
