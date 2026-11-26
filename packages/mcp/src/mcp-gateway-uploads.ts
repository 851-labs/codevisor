import { randomUUID } from "node:crypto"
import {
  mkdirSync,
  readdirSync,
  readFileSync,
  realpathSync,
  rmSync,
  statSync,
  writeFileSync
} from "node:fs"
import { basename, isAbsolute, join, relative, resolve } from "node:path"

import {
  decode,
  FLEET_UPLOAD_FILES_PATH,
  FleetUploadFiles,
  isExternalClientKey,
  type FleetUploadFile
} from "@codevisor/api"

import type { GatewayOrigin, McpManagerConfig } from "./mcp-manager-types.js"
import { run } from "./mcp-support.js"

const remoteUploadMaxBytes = 20 * 1024 * 1024

export interface GatewayUploads {
  readonly uploadPaths: (
    sessionId: string,
    remote: GatewayOrigin | undefined,
    toolName: string,
    args: Readonly<Record<string, unknown>>
  ) => Promise<Array<string>>
  readonly readForMachine: (
    sessionId: string,
    paths: ReadonlyArray<string>
  ) => Promise<FleetUploadFiles>
}

export const uploadsFiles = (
  toolName: string,
  args: Readonly<Record<string, unknown>>
): boolean => {
  if (!uploadTools.has(toolName)) return false
  return !clearsFileInput(toolName, args)
}

export const makeGatewayUploads = (
  config: Pick<McpManagerConfig, "dataDir" | "db" | "remoteInvoker">,
  selfMachine: { readonly id: string; readonly name: string }
): GatewayUploads => {
  const stagingRoot = join(config.dataDir, "browser", "remote-uploads")

  const workspaceFiles = async (
    sessionId: string,
    paths: ReadonlyArray<string>
  ): Promise<Array<string>> => {
    const { cwd } = await run(config.db.getSessionSummary(sessionId))
    if (cwd === undefined) throw new Error("This session has no workspace folder")

    const workspaceRoot = realpathSync(cwd)
    return paths.map((path) => workspaceFile(workspaceRoot, path))
  }

  const filesFromCaller = async (
    remote: GatewayOrigin,
    paths: ReadonlyArray<string>
  ): Promise<ReadonlyArray<FleetUploadFile>> => {
    if (remote.sessionId === undefined) throw callerHasNoChat(remote)
    if (config.remoteInvoker === undefined) throw callerUnreachable(remote)

    const answer = await config.remoteInvoker(
      remote.machineId,
      FLEET_UPLOAD_FILES_PATH,
      { sessionId: remote.sessionId, paths },
      { machineId: selfMachine.id, machineName: selfMachine.name }
    )
    return decode(FleetUploadFiles)(answer).files
  }

  const uploadPaths: GatewayUploads["uploadPaths"] = async (sessionId, remote, toolName, args) => {
    const paths = requestedPaths(toolName, args)
    if (remote !== undefined) return stage(stagingRoot, await filesFromCaller(remote, paths))
    if (isExternalClientKey(sessionId)) throw externalClientHasNoWorkspace()

    return workspaceFiles(sessionId, paths)
  }

  const readForMachine: GatewayUploads["readForMachine"] = async (sessionId, paths) => {
    const files = await workspaceFiles(sessionId, requestedPaths("upload", { paths }))
    if (totalBytes(files) > remoteUploadMaxBytes) throw tooLargeToSend()

    return { files: files.map(encodedFile) }
  }

  return { uploadPaths, readForMachine }
}

const uploadTools = new Set([
  "upload_files",
  "playwright.fileChooserSetFiles",
  "playwright.setInputFiles"
])

const stagedUploadLifetimeMs = 24 * 60 * 60 * 1000

const clearsFileInput = (toolName: string, args: Readonly<Record<string, unknown>>): boolean =>
  toolName === "playwright.setInputFiles" && Array.isArray(args.paths) && args.paths.length === 0

const requestedPaths = (
  toolName: string,
  args: Readonly<Record<string, unknown>>
): Array<string> => {
  const paths = Array.isArray(args.paths) ? args.paths : []
  if (paths.length === 0 || !paths.every((path) => typeof path === "string")) {
    throw new Error(`${toolName} requires one or more workspace file paths`)
  }
  return paths
}

const workspaceFile = (workspaceRoot: string, path: string): string => {
  const candidate = realpathSync(isAbsolute(path) ? path : resolve(workspaceRoot, path))
  if (outsideFolder(workspaceRoot, candidate)) {
    throw new Error("Browser Use can only upload files from the current workspace")
  }
  if (!statSync(candidate).isFile()) throw new Error(`Upload path is not a file: ${path}`)
  return candidate
}

const outsideFolder = (folder: string, path: string): boolean => {
  const inside = relative(folder, path)
  return inside.startsWith("..") || isAbsolute(inside)
}

const totalBytes = (paths: ReadonlyArray<string>): number =>
  paths.reduce((sum, path) => sum + statSync(path).size, 0)

const encodedFile = (path: string): FleetUploadFile => ({
  name: basename(path),
  data: readFileSync(path).toString("base64")
})

const stage = (root: string, files: ReadonlyArray<FleetUploadFile>): Array<string> => {
  removeExpiredUploads(root)

  const folder = join(root, randomUUID())
  return files.map((file, index) => stagedFile(join(folder, String(index)), file))
}

const stagedFile = (folder: string, file: FleetUploadFile): string => {
  mkdirSync(folder, { recursive: true, mode: 0o700 })
  const path = join(folder, safeFileName(file.name))
  writeFileSync(path, Buffer.from(file.data, "base64"), { mode: 0o600 })
  return path
}

const safeFileName = (name: string): string => {
  const plain = basename(name)
  if (plain === "" || plain === "." || plain === "..") return "file"
  return plain
}

const removeExpiredUploads = (root: string): void => {
  mkdirSync(root, { recursive: true, mode: 0o700 })

  const cutoff = Date.now() - stagedUploadLifetimeMs
  for (const name of readdirSync(root)) {
    const folder = join(root, name)
    if (statSync(folder).mtimeMs < cutoff) rmSync(folder, { recursive: true, force: true })
  }
}

const callerHasNoChat = (remote: GatewayOrigin): Error =>
  new Error(
    `Browser Use uploads files from a chat's workspace folder; this call from ${remote.machineName} isn't from a chat`
  )

const callerUnreachable = (remote: GatewayOrigin): Error =>
  new Error(
    `Browser Use can't fetch the files from ${remote.machineName}: this server has no machine link`
  )

const externalClientHasNoWorkspace = (): Error =>
  new Error(
    "Browser Use uploads files from a Codevisor chat's workspace folder; an MCP client outside Codevisor has none"
  )

const tooLargeToSend = (): Error =>
  new Error(
    `These files are too large to send to another machine for upload; the limit is ${remoteUploadMaxBytes / (1024 * 1024)} MB per upload`
  )
