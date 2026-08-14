import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

export interface ServerResourceOptions {
  readonly moduleDirectory?: string
  readonly workingDirectory?: string
  readonly resourceDirectory?: string
}

const unique = (values: ReadonlyArray<string | undefined>): ReadonlyArray<string> => [
  ...new Set(values.filter((value): value is string => value !== undefined && value.length > 0))
]

/// Server resources have one logical root even though development and packaged
/// runtimes currently place that root differently. Keep the layout knowledge
/// here so individual features never depend on process.cwd() or invent their
/// own candidate lists.
export const serverResourceDirectories = (
  options: ServerResourceOptions = {}
): ReadonlyArray<string> => {
  const moduleDirectory = options.moduleDirectory ?? dirname(fileURLToPath(import.meta.url))
  const workingDirectory = options.workingDirectory ?? process.cwd()
  return unique([
    options.resourceDirectory,
    process.env.CODEVISOR_SERVER_RESOURCES,
    // Package layout, source and release alike: this module compiles to
    // packages/automation/{src,dist}/*.js next to packages/automation/resources,
    // and the packaged runtime preserves the same per-package shape.
    join(moduleDirectory, "..", "resources"),
    // Compatibility fallbacks for direct source-tree launches.
    join(workingDirectory, "packages", "automation", "resources"),
    join(workingDirectory, "resources")
  ])
}

export const findServerResource = (
  relativePath: string,
  options: ServerResourceOptions = {},
  validate: (candidate: string) => boolean = existsSync
): string | undefined =>
  serverResourceDirectories(options)
    .map((directory) => join(directory, relativePath))
    .find(validate)

export const requireServerResource = (
  relativePath: string,
  description: string,
  options: ServerResourceOptions = {},
  validate?: (candidate: string) => boolean
): string => {
  const resource = findServerResource(relativePath, options, validate)
  if (resource === undefined) throw new Error(`Missing ${description}`)
  return resource
}
