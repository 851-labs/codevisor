import { join, resolve, sep } from "node:path"

import { run, type CodevisorServerServices } from "./server-context.js"
import { asRecord } from "./unknown-values.js"

export interface ProtectedFolder {
  readonly id: string
  readonly name: string
  readonly path: string
}

export type FolderDecision = "allowed" | "declined"

export type FolderDecisions = Readonly<Record<string, FolderDecision>>

export type PathAccess =
  | { readonly kind: "open" }
  | { readonly kind: "never" }
  | { readonly kind: "held"; readonly folder: ProtectedFolder }

export type FolderAccess = (path: string) => PathAccess

export interface FolderMachine {
  readonly platform: NodeJS.Platform
  readonly homeDirectory: string
}

export const openFolderAccess: FolderAccess = () => open

export const folderAccess = (
  decisions: FolderDecisions | undefined,
  machine: FolderMachine
): FolderAccess => {
  if (decisions === undefined || machine.platform !== "darwin") return openFolderAccess

  const home = resolve(machine.homeDirectory)
  return (path) => {
    if (isOtherAppData(path, home)) return never
    const folder = protectedFolderFor(path, home)
    if (folder === undefined) return open

    return accessAfter(decisions[folder.id], folder)
  }
}

export const readFolderDecisions = async (
  services: CodevisorServerServices
): Promise<FolderDecisions | undefined> => {
  const stored = await run(services.db.getMachineSetting(folderDecisionsSetting))
  return stored === undefined ? undefined : decodeDecisions(stored)
}

export const beginFolderDecisions = async (
  services: CodevisorServerServices
): Promise<FolderDecisions> => {
  const existing = await readFolderDecisions(services)
  if (existing !== undefined) return existing

  await writeFolderDecisions(services, {})
  return {}
}

export const recordFolderDecision = async (
  services: CodevisorServerServices,
  folderId: string,
  decision: FolderDecision
): Promise<void> => {
  const decisions = (await readFolderDecisions(services)) ?? {}
  await writeFolderDecisions(services, { ...decisions, [folderId]: decision })
}

const folderDecisionsSetting = "protected-folders"

const open: PathAccess = { kind: "open" }

const never: PathAccess = { kind: "never" }

const homeFolderNames = ["Desktop", "Documents", "Downloads"]

const otherAppDataFolders = ["Containers", "Group Containers", "Mobile Documents", "CloudStorage"]

const volumesRoot = "/Volumes"

const accessAfter = (decision: FolderDecision | undefined, folder: ProtectedFolder): PathAccess => {
  if (decision === "allowed") return open
  if (decision === "declined") return never
  return { kind: "held", folder }
}

const protectedFolderFor = (path: string, home: string): ProtectedFolder | undefined =>
  homeFolders(home).find((folder) => isInside(path, folder.path)) ?? volumeOf(path)

const homeFolders = (home: string): ReadonlyArray<ProtectedFolder> =>
  homeFolderNames.map((name) => ({ id: name.toLowerCase(), name, path: join(home, name) }))

const volumeOf = (path: string): ProtectedFolder | undefined => {
  if (!path.startsWith(`${volumesRoot}${sep}`)) return undefined
  const name = path.slice(volumesRoot.length + 1).split(sep)[0]
  if (name === undefined || name.length === 0) return undefined

  return { id: `volume:${name}`, name, path: join(volumesRoot, name) }
}

const isOtherAppData = (path: string, home: string): boolean =>
  otherAppDataFolders.some((name) => isInside(path, join(home, "Library", name)))

const isInside = (path: string, root: string): boolean =>
  path === root || path.startsWith(`${root}${sep}`)

const writeFolderDecisions = (
  services: CodevisorServerServices,
  decisions: FolderDecisions
): Promise<void> =>
  run(services.db.setMachineSetting(folderDecisionsSetting, JSON.stringify(decisions)))

const decodeDecisions = (stored: string): FolderDecisions => {
  try {
    return Object.fromEntries(Object.entries(asRecord(JSON.parse(stored))).filter(isDecision))
  } catch {
    return {}
  }
}

const isDecision = (entry: [string, unknown]): entry is [string, FolderDecision] =>
  entry[1] === "allowed" || entry[1] === "declined"
