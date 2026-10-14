import { existsSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

export interface ServerResourceOptions {
  readonly moduleDirectory?: string
  readonly workingDirectory?: string
}

const unique = (values: ReadonlyArray<string | undefined>): ReadonlyArray<string> => [
  ...new Set(values.filter((value): value is string => value !== undefined && value.length > 0))
]

export const serverResourceDirectories = (
  options: ServerResourceOptions = {}
): ReadonlyArray<string> => {
  const moduleDirectory = options.moduleDirectory ?? dirname(fileURLToPath(import.meta.url))
  const workingDirectory = options.workingDirectory ?? process.cwd()
  return unique([
    process.env.CODEVISOR_SERVER_RESOURCES,
    join(moduleDirectory, "..", "resources"),
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
