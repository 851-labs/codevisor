import { randomUUID } from "node:crypto"
import {
  chmod,
  copyFile,
  lstat,
  mkdir,
  readdir,
  readlink,
  rename,
  rm,
  stat,
  symlink,
  utimes
} from "node:fs/promises"
import { homedir } from "node:os"
import { basename, dirname, join, resolve } from "node:path"

const metadataAt = async (filePath: string) => {
  try {
    return await lstat(filePath)
  } catch (cause) {
    if ((cause as NodeJS.ErrnoException).code === "ENOENT") return undefined
    throw cause
  }
}

const copyNewerFile = async (source: string, destination: string): Promise<void> => {
  const sourceMetadata = await stat(source)
  const destinationMetadata = await metadataAt(destination)
  if (destinationMetadata !== undefined && !destinationMetadata.isFile()) {
    throw new Error(`Cannot merge Claude conversation file over non-file: ${destination}`)
  }
  if (
    destinationMetadata?.isFile() === true &&
    destinationMetadata.mtimeMs >= sourceMetadata.mtimeMs
  ) {
    return
  }

  const temporary = join(dirname(destination), `.${basename(destination)}.${randomUUID()}.tmp`)
  try {
    await copyFile(source, temporary)
    await chmod(temporary, sourceMetadata.mode)
    await utimes(temporary, sourceMetadata.atime, sourceMetadata.mtime)
    try {
      await rename(temporary, destination)
    } catch (cause) {
      const code = (cause as NodeJS.ErrnoException).code
      if (process.platform !== "win32" || (code !== "EEXIST" && code !== "EPERM")) throw cause
      await rm(destination, { force: true })
      await rename(temporary, destination)
    }
  } finally {
    await rm(temporary, { force: true })
  }
}

const mergeConversationTree = async (source: string, destination: string): Promise<void> => {
  await mkdir(destination, { mode: 0o700, recursive: true })
  const entries = await readdir(source, { withFileTypes: true })
  await Promise.all(
    entries.map(async (entry) => {
      const sourceEntry = join(source, entry.name)
      const destinationEntry = join(destination, entry.name)
      if (entry.isDirectory()) {
        const destinationMetadata = await metadataAt(destinationEntry)
        if (destinationMetadata !== undefined && !destinationMetadata.isDirectory()) {
          throw new Error(
            `Cannot merge Claude conversation directory over file: ${destinationEntry}`
          )
        }
        await mergeConversationTree(sourceEntry, destinationEntry)
        return
      }
      if (entry.isFile()) {
        await copyNewerFile(sourceEntry, destinationEntry)
        return
      }
      throw new Error(`Unsupported entry in Claude conversation storage: ${sourceEntry}`)
    })
  )
}

const installSharedProjectsLink = async (
  managedProfilePath: string,
  sharedProjectsPath: string
): Promise<void> => {
  const managedProjectsPath = join(managedProfilePath, "projects")
  if (resolve(managedProjectsPath) === resolve(sharedProjectsPath)) return
  await mkdir(managedProfilePath, { mode: 0o700, recursive: true })
  await chmod(managedProfilePath, 0o700)

  const existing = await metadataAt(managedProjectsPath)
  if (existing?.isSymbolicLink() === true) {
    const target = resolve(dirname(managedProjectsPath), await readlink(managedProjectsPath))
    if (target === resolve(sharedProjectsPath)) return
  } else if (existing !== undefined && !existing.isDirectory()) {
    throw new Error(`Claude projects path is not a directory: ${managedProjectsPath}`)
  }

  if (existing !== undefined) {
    await mergeConversationTree(managedProjectsPath, sharedProjectsPath)
  }

  const identifier = randomUUID()
  const temporaryLink = join(managedProfilePath, `.projects.${identifier}.link`)
  const backup = join(managedProfilePath, `.projects.${identifier}.backup`)
  await symlink(
    resolve(sharedProjectsPath),
    temporaryLink,
    process.platform === "win32" ? "junction" : "dir"
  )
  if (existing === undefined) {
    try {
      await rename(temporaryLink, managedProjectsPath)
    } finally {
      await rm(temporaryLink, { force: true })
    }
    return
  }

  try {
    await rename(managedProjectsPath, backup)
  } catch (cause) {
    await rm(temporaryLink, { force: true })
    throw cause
  }
  try {
    await rename(temporaryLink, managedProjectsPath)
  } catch (cause) {
    await rename(backup, managedProjectsPath)
    throw cause
  } finally {
    await rm(temporaryLink, { force: true })
  }
  await rm(backup, { force: true, recursive: true })
}

export const defaultClaudeConfigPath = (environment: NodeJS.ProcessEnv): string => {
  const configured = environment.CLAUDE_CONFIG_DIR?.trim()
  if (configured !== undefined && configured.length > 0) return resolve(configured)
  const home = environment.HOME?.trim()
  return join(home === undefined || home.length === 0 ? homedir() : resolve(home), ".claude")
}

/// Claude couples credentials and conversations under CLAUDE_CONFIG_DIR. Keep
/// each managed root for authentication, but point its projects directory at
/// the default profile's canonical history so every account can resume every
/// chat without copying mutable transcripts during an account switch.
export const ensureSharedClaudeConversations = async (
  defaultConfigPath: string,
  managedProfilePaths: ReadonlyArray<string>
): Promise<void> => {
  const sharedProjectsPath = join(defaultConfigPath, "projects")
  await mkdir(sharedProjectsPath, { mode: 0o700, recursive: true })
  const profiles = [...new Set(managedProfilePaths.map((profile) => resolve(profile)))].toSorted()
  await profiles.reduce(
    (previous, profile) =>
      previous.then(() => installSharedProjectsLink(profile, sharedProjectsPath)),
    Promise.resolve()
  )
}
