import { execFile, execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import { chmodSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs"
import { createServer as createHttpServer } from "node:http"
import { createServer, type Socket } from "node:net"
import { tmpdir } from "node:os"
import { join } from "node:path"
import { promisify } from "node:util"

import { makeGitHosts, type GitHosts } from "@codevisor/git-hosts"
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

export const startServer = async (env: NodeJS.ProcessEnv = process.env, gitHosts?: GitHosts) => {
  const { services } = await makeServices("server-a")
  const server = await startWithApp({
    ...services,
    resolveGitEnvironment: async () => env,
    ...(gitHosts === undefined ? {} : { gitHosts })
  })
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
  const version = `[ "$1" = "--version" ] && echo "${name} version 1.0.0" && exit 0`
  writeFileSync(path, `#!/bin/sh\n${version}\n${script}\n`)
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

export const isolatedGitEnv = (bin = tempDir("codevisor-empty-bin-")): NodeJS.ProcessEnv => {
  const home = tempDir("codevisor-git-home-")
  return {
    PATH: `${bin}:/usr/bin:/bin`,
    HOME: home,
    GH_CONFIG_DIR: join(home, "gh"),
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1"
  }
}

export interface FakeGhRelease {
  readonly gitHosts: GitHosts
  readonly toolsDir: string
  readonly downloads: () => number
}

const fakeGhVersion = "9.1.0"
const fakeGhArchive = `gh_${fakeGhVersion}_linux_amd64.tar.gz`
const fakeGhReleases = "/cli/cli/releases"

export const fakeGhRelease = async (
  ghScript: string,
  { checksum }: { readonly checksum?: string } = {}
): Promise<FakeGhRelease> => {
  const root = tempDir("codevisor-gh-release-")
  const archive = ghReleaseArchive(root, ghScript)
  let downloads = 0
  const routes: Record<string, () => { readonly status: number; readonly body: string | Buffer }> =
    {
      [`${fakeGhReleases}/latest`]: () => ({ status: 302, body: "" }),
      [`${fakeGhReleases}/tag/v${fakeGhVersion}`]: () => ({ status: 200, body: "release" }),
      [`${fakeGhReleases}/download/v${fakeGhVersion}/gh_${fakeGhVersion}_checksums.txt`]: () => ({
        status: 200,
        body: `${checksum ?? createHash("sha256").update(archive).digest("hex")}  ${fakeGhArchive}\n`
      }),
      [`${fakeGhReleases}/download/v${fakeGhVersion}/${fakeGhArchive}`]: () => {
        downloads += 1
        return { status: 200, body: archive }
      }
    }
  const server = createHttpServer((request, response) => {
    const route = routes[request.url ?? ""]?.() ?? { status: 404, body: "" }
    const location = { location: `${fakeGhReleases}/tag/v${fakeGhVersion}` }
    setTimeout(() => response.writeHead(route.status, location).end(route.body), 300)
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  onTestFinished(() => new Promise<void>((resolve) => server.close(() => resolve())))
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("No port")
  const { port } = address
  const toolsDir = join(root, "tools")
  const gitHosts = makeGitHosts({
    toolsDir,
    platform: { os: "linux", arch: "x64" },
    releasesUrls: { github: `http://127.0.0.1:${String(port)}${fakeGhReleases}` }
  })
  return { gitHosts, toolsDir, downloads: () => downloads }
}

const ghReleaseArchive = (root: string, ghScript: string): Buffer => {
  const bin = join(root, "content", `gh_${fakeGhVersion}_linux_amd64`, "bin")
  mkdirSync(bin, { recursive: true })
  writeFileSync(
    join(bin, "gh"),
    `#!/bin/sh\n[ "$1" = "--version" ] && echo "gh version ${fakeGhVersion}" && exit 0\n${ghScript}\n`
  )
  chmodSync(join(bin, "gh"), 0o755)
  const archive = join(root, fakeGhArchive)
  execFileSync("tar", ["-czf", archive, "-C", join(root, "content"), "."])
  return readFileSync(archive)
}
