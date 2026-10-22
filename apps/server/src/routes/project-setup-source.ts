import { lstat, readFile } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { homedir } from "node:os"
import { basename, isAbsolute, join, normalize, relative } from "node:path"

import type {
  Project,
  ProjectEnvFile,
  ProjectEnvFileContent,
  ProjectLocation,
  ProjectSetupSource
} from "@codevisor/api"
import { ReadProjectEnvFilesRequest as ReadProjectEnvFilesRequestSchema } from "@codevisor/api"
import { needsInitialCommit, runGit } from "@codevisor/worktrees"

import {
  existingDirectory,
  getProjectOrFail,
  HttpFailure,
  localLocationOrFail,
  readSchema,
  writeJson,
  type CodevisorServerServices
} from "../server-context.js"

export const ENV_FILE_MAX_BYTES = 1024 * 1024
const ENV_FILE_LIMIT = 200
const envFilePattern = /^(?:\.env(?:\..+)?|\.envrc|\.dev\.vars(?:\..+)?)$/

export const isEnvFileName = (name: string): boolean => envFilePattern.test(name)

export const isSafeRelativePath = (path: string): boolean =>
  !isAbsolute(path) && normalize(path) === path && !path.split("/").includes("..")

export const gitEnvironment = (services: CodevisorServerServices): Promise<NodeJS.ProcessEnv> =>
  services.resolveGitEnvironment?.() ?? Promise.resolve(process.env)

export const listEnvFiles = async (
  folderPath: string,
  env?: NodeJS.ProcessEnv
): Promise<ReadonlyArray<ProjectEnvFile>> => {
  const output = await runGit(
    "list-env-files",
    ["ls-files", "--others", "--directory", "--no-empty-directory", "-z"],
    folderPath,
    env,
    { maxBuffer: 4 * 1024 * 1024 }
  ).catch(() => "")
  const candidates = output
    .split("\0")
    .filter((path) => path.length > 0 && !path.endsWith("/"))
    .filter((path) => isEnvFileName(basename(path)) && isSafeRelativePath(path))
    .toSorted((left, right) => left.localeCompare(right))
    .slice(0, ENV_FILE_LIMIT)
  const files = await Promise.all(
    candidates.map(async (path): Promise<ProjectEnvFile | undefined> => {
      const stats = await lstat(join(folderPath, path))
      return stats.isFile() && stats.size <= ENV_FILE_MAX_BYTES
        ? { path, size: stats.size }
        : undefined
    })
  )
  return files.filter((file) => file !== undefined)
}

const homeRelativePath = (folderPath: string): string | undefined => {
  const path = relative(homedir(), folderPath)
  return isSafeRelativePath(path) ? path : undefined
}

export const localFolderOrFail = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string
): Promise<{ project: Project; location: ProjectLocation; folderPath: string }> => {
  const project = await getProjectOrFail(services.db, projectId)
  const location = localLocationOrFail(serverId, project)
  const folderPath = location.folderPath
  if (existingDirectory(folderPath) === undefined) {
    throw new HttpFailure(404, `Project folder is missing on this machine: ${folderPath}`)
  }
  return { project, location, folderPath }
}

export const routeProjectSetupSource = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string,
  response: ServerResponse
): Promise<void> => {
  const { folderPath, project } = await localFolderOrFail(services, serverId, projectId)
  const env = await gitEnvironment(services)
  const [envFiles, initialCommit] = await Promise.all([
    listEnvFiles(folderPath, env),
    needsInitialCommit(folderPath, env)
  ])
  const relativePath = homeRelativePath(folderPath)
  const source: ProjectSetupSource = {
    projectId: project.id,
    folderPath,
    ...(relativePath === undefined ? {} : { homeRelativePath: relativePath }),
    envFiles,
    needsInitialCommit: initialCommit
  }
  writeJson(response, 200, source)
}

export const routeReadProjectEnvFiles = async (
  services: CodevisorServerServices,
  serverId: string,
  projectId: string,
  request: IncomingMessage,
  response: ServerResponse
): Promise<void> => {
  const payload = await readSchema(request, ReadProjectEnvFilesRequestSchema)
  const { folderPath } = await localFolderOrFail(services, serverId, projectId)
  const env = await gitEnvironment(services)
  const available = new Set((await listEnvFiles(folderPath, env)).map((file) => file.path))
  const files: Array<ProjectEnvFileContent> = []
  for (const path of payload.paths) {
    if (!available.has(path)) {
      throw new HttpFailure(400, `Not an env file in this project: ${path}`)
    }
    files.push({ path, contents: await readFile(join(folderPath, path), "utf8") })
  }
  writeJson(response, 200, { files })
}
