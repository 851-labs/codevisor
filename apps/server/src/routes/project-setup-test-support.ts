import { execFile } from "node:child_process"
import { chmodSync, mkdirSync, mkdtempSync, writeFileSync } from "node:fs"
import { createServer, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { expect, onTestFinished } from "vitest"

import { jsonRequest, makeServices, startWithApp, tempDirs } from "../test-support.js"

const execFileAsync = promisify(execFile)

export const git = (args: ReadonlyArray<string>, cwd: string) =>
  execFileAsync("git", ["-c", "user.email=t@t", "-c", "user.name=t", ...args], { cwd })

export const tempDir = (prefix: string, parent = tmpdir()): string => {
  const path = mkdtempSync(join(parent, prefix))
  tempDirs.push(path)
  return path
}

export const makeOrigin = async (): Promise<string> => {
  const repo = join(tempDir("codevisor-setup-origin-"), "widget")
  mkdirSync(repo)
  await git(["init", "-b", "main"], repo)
  writeFileSync(join(repo, ".gitignore"), ".env*\n.dev.vars\nnode_modules/\n")
  writeFileSync(join(repo, "README.md"), "hello")
  mkdirSync(join(repo, "apps", "web"), { recursive: true })
  writeFileSync(join(repo, "apps", "web", "index.ts"), "export {}")
  await git(["add", "."], repo)
  await git(["commit", "-m", "init"], repo)
  return repo
}

export const startServer = async (env: NodeJS.ProcessEnv = process.env) => {
  const { services } = await makeServices("server-a")
  const server = await startWithApp({ ...services, resolveGitEnvironment: async () => env })
  return { server, services }
}

export type TestServer = Awaited<ReturnType<typeof startServer>>["server"]

export const useBaseFolder = async (server: TestServer): Promise<string> => {
  const baseFolder = tempDir("codevisor-setup-base-")
  const saved = await jsonRequest(server, "/v1/projects/clone-settings", {
    body: JSON.stringify({ baseFolder }),
    method: "PUT"
  })
  expect(saved.body).toMatchObject({ baseFolder })
  return baseFolder
}

export const fakeCli = (name: string, script: string): NodeJS.ProcessEnv => {
  const bin = tempDir(`codevisor-fake-${name}-`)
  const path = join(bin, name)
  writeFileSync(path, `#!/bin/sh\n${script}\n`)
  chmodSync(path, 0o755)
  return { ...process.env, PATH: `${bin}:/usr/bin:/bin` }
}

export const silentGitDaemon = async (): Promise<{
  readonly url: string
  readonly connected: Promise<void>
}> => {
  const sockets: Array<Socket> = []
  const { promise: connected, resolve: markConnected } = Promise.withResolvers<void>()
  const server = createServer((socket) => {
    sockets.push(socket)
    markConnected()
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  onTestFinished(async () => {
    for (const socket of sockets) socket.destroy()
    await new Promise((resolve) => server.close(resolve))
  })
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("No port")
  return { url: `git://127.0.0.1:${String(address.port)}/widget.git`, connected }
}
