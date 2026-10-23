import { execFileSync } from "node:child_process"
import { createHash } from "node:crypto"
import {
  chmodSync,
  existsSync,
  mkdirSync,
  mkdtempSync,
  readFileSync,
  rmSync,
  symlinkSync,
  writeFileSync
} from "node:fs"
import { createServer } from "node:http"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"

import { onTestFinished } from "vitest"

export const testTempDir = (prefix: string): string => {
  const root = mkdtempSync(join(tmpdir(), prefix))
  onTestFinished(() => rmSync(root, { recursive: true, force: true }))
  return root
}

const scriptTools = ["sleep"] as const

const scriptToolsBin = (): string => {
  const bin = testTempDir("codevisor-script-tools-")
  for (const tool of scriptTools) {
    const source = ["/bin", "/usr/bin"].map((directory) => join(directory, tool)).find(existsSync)
    if (source === undefined) throw new Error(`No ${tool} for fake CLI scripts`)
    symlinkSync(source, join(bin, tool))
  }
  return bin
}

export const isolatedEnv = (bin: string): NodeJS.ProcessEnv => {
  const home = testTempDir("codevisor-git-host-home-")
  return {
    PATH: `${bin}:${scriptToolsBin()}`,
    HOME: home,
    GH_CONFIG_DIR: join(home, "gh"),
    GLAB_CONFIG_DIR: join(home, "glab"),
    GIT_CONFIG_GLOBAL: "/dev/null",
    GIT_CONFIG_NOSYSTEM: "1"
  }
}

export const writeScript = (path: string, script: string): string => {
  writeFileSync(path, `#!/bin/sh\n${script}\n`)
  chmodSync(path, 0o755)
  return path
}

export interface FakeCli {
  readonly env: NodeJS.ProcessEnv
  readonly bin: string
  readonly path: string
}

export const fakeCli = (name: string, script: string): FakeCli => {
  const bin = join(testTempDir(`codevisor-fake-${name}-`), "bin")
  mkdirSync(bin)
  const path = writeScript(join(bin, name), script)
  return { env: isolatedEnv(bin), bin, path }
}

export const emptyEnv = (): NodeJS.ProcessEnv => isolatedEnv(testTempDir("codevisor-empty-bin-"))

export interface ReleaseRoute {
  readonly status?: number
  readonly redirect?: string
  readonly body?: string | Buffer
  readonly cutOff?: boolean
}

export interface ReleaseServer {
  readonly url: string
  readonly requests: ReadonlyArray<string>
}

export const startReleaseServer = async (
  routes: Readonly<Record<string, ReleaseRoute>>
): Promise<ReleaseServer> => {
  const requests: Array<string> = []
  const server = createServer((request, response) => {
    const path = request.url ?? "/"
    requests.push(path)
    const route = routes[path] ?? { status: 404, body: "not found" }
    if (route.cutOff === true) {
      response.writeHead(200, { "content-length": "100000" })
      response.write("partial")
      setTimeout(() => response.destroy(), 20)
      return
    }
    const headers = route.redirect === undefined ? {} : { location: route.redirect }
    response.writeHead(route.status ?? (route.redirect === undefined ? 200 : 302), headers)
    response.end(route.body ?? "")
  })
  await new Promise<void>((resolve) => server.listen(0, "127.0.0.1", resolve))
  onTestFinished(() => new Promise<void>((resolve) => server.close(() => resolve())))
  const address = server.address()
  if (address === null || typeof address === "string") throw new Error("No port")
  const { port } = address
  return { url: `http://127.0.0.1:${String(port)}`, requests }
}

export interface FakeArchive {
  readonly name: string
  readonly bytes: Buffer
  readonly sha256: string
}

export const fakeArchive = (
  name: string,
  binaryPath: string,
  script: string,
  format: "tar.gz" | "zip" = "tar.gz"
): FakeArchive => {
  const root = testTempDir("codevisor-fake-release-")
  const content = join(root, "content")
  mkdirSync(join(content, dirname(binaryPath)), { recursive: true })
  writeScript(join(content, binaryPath), script)
  const archive = join(root, name)
  const formatArgs = format === "zip" ? ["--format", "zip", "-cf"] : ["-czf"]
  execFileSync("tar", [...formatArgs, archive, "-C", content, "."])
  const bytes = readFileSync(archive)
  return { name, bytes, sha256: sha256Of(bytes) }
}

export const sha256Of = (bytes: Buffer): string => createHash("sha256").update(bytes).digest("hex")

export const versionScript = (output: string): string =>
  `[ "$1" = "--version" ] && echo "${output}"\nexit 0`
