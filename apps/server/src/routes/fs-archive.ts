import { spawn, type ChildProcessByStdio } from "node:child_process"
import { stat } from "node:fs/promises"
import type { IncomingMessage, ServerResponse } from "node:http"
import { basename, dirname } from "node:path"
import type { Readable } from "node:stream"

import { HttpFailure } from "../server-context.js"
import { stringField } from "../unknown-values.js"
import { expandFsPath } from "./fs-paths.js"

type TarProcess = ChildProcessByStdio<null, Readable, null>

export const sendFilesystemArchive = async (
  request: IncomingMessage,
  response: ServerResponse,
  url: URL
): Promise<boolean> => {
  const path = expandFsPath(url.searchParams.get("path") ?? "")
  await requireExisting(path)

  const tar = startTar(path)
  writeArchiveHead(response, path)
  streamUntilTarExits(tar, response)
  stopTarWhenClientLeaves(tar, request, response)
  return true
}

const requireExisting = async (path: string): Promise<void> => {
  try {
    await stat(path)
  } catch (cause) {
    throwArchiveFailure(path, cause)
  }
}

const startTar = (path: string): TarProcess =>
  spawn("tar", ["-c", "-f", "-", "-C", dirname(path), `./${basename(path)}`], {
    env: { ...process.env, COPYFILE_DISABLE: "1" },
    stdio: ["ignore", "pipe", "ignore"]
  })

const writeArchiveHead = (response: ServerResponse, path: string): void => {
  response.writeHead(200, {
    "content-type": "application/x-tar",
    "cache-control": "private, no-store",
    "content-disposition": `attachment; filename*=UTF-8''${encodeURIComponent(basename(path))}.tar`
  })
}

const streamUntilTarExits = (tar: TarProcess, response: ServerResponse): void => {
  tar.stdout.pipe(response, { end: false })
  tar.once("error", (cause) => response.destroy(cause))
  tar.once("close", (code) => {
    if (code === 0) response.end()
    else response.destroy(new Error(`tar exited with ${code}`))
  })
}

const stopTarWhenClientLeaves = (
  tar: TarProcess,
  request: IncomingMessage,
  response: ServerResponse
): void => {
  const stop = (): void => {
    if (tar.exitCode === null && tar.signalCode === null) tar.kill()
  }
  request.once("aborted", stop)
  response.once("close", stop)
}

const throwArchiveFailure = (path: string, cause: unknown): never => {
  const code = stringField(cause, "code") ?? ""
  if (code === "ENOENT") throw new HttpFailure(404, `No such file or folder: ${path}`, "not_found")
  if (["EACCES", "EPERM"].includes(code)) {
    throw new HttpFailure(403, `Permission denied: ${path}`, "permission_denied")
  }
  throw cause
}
