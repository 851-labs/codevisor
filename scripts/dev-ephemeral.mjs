import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { createReadStream } from "node:fs"
import { mkdir, mkdtemp, readFile, readdir, rename, rm, stat, writeFile } from "node:fs/promises"
import { createServer } from "node:http"
import { homedir, networkInterfaces } from "node:os"
import { join, relative } from "node:path"

import { withArtifactLock } from "./artifact-lock.mjs"
import { describeExit, pathExists, waitForExit } from "./dev-shared.mjs"

const archivePattern = /^codevisor-server-[a-z0-9-]+\.tar\.gz(\.sha256)?$/
const inputsKeyFile = "inputs.sha256"

export async function resolveDevVmHost({
  tartInstalled = isTartInstalled,
  defaultRoute = defaultRouteInterface,
  interfaces = networkInterfaces
} = {}) {
  if (!(await tartInstalled())) return undefined

  const name = await defaultRoute()
  if (name === undefined) return undefined

  return interfaces()[name]?.find((address) => address.family === "IPv4" && !address.internal)
    ?.address
}

export async function ensureDevServerArchive({ repoRoot, archiveRoot }) {
  const target = (await capture(join(repoRoot, "scripts/release/detect-target.sh"), [])).trim()
  const archive = join(archiveRoot, `codevisor-server-${target}.tar.gz`)
  const key = await serverInputsKey(repoRoot, target)
  if ((await cachedKey(archiveRoot)) === key && (await pathExists(archive))) return archive

  await buildServerArchive({ repoRoot, archiveRoot, target })
  await writeFile(join(archiveRoot, inputsKeyFile), key)
  return archive
}

export async function serveDevEphemeralArtifacts({ repoRoot, archiveRoot, host }) {
  const files = await artifactFiles(repoRoot, archiveRoot)
  const server = createServer((request, response) => {
    const path = request.method === "GET" ? files.get(pathnameOf(request.url)) : undefined
    if (path === undefined) {
      response.writeHead(404).end()
      return
    }
    response.writeHead(200, { "content-type": "application/octet-stream" })
    createReadStream(path)
      .on("error", () => response.destroy())
      .pipe(response)
  })
  await new Promise((resolve, reject) => {
    server.once("error", reject)
    server.listen(0, host, resolve)
  })
  return { server, url: `http://${host}:${server.address().port}` }
}

export const devEphemeralEnvironment = ({ artifactsUrl, vmHost, cloudPort, appBundle }) => ({
  CODEVISOR_DEV_EPHEMERAL_ARTIFACTS_URL: artifactsUrl,
  CODEVISOR_DEV_EPHEMERAL_CLOUD_URL: `http://${vmHost}:${cloudPort}`,
  CODEVISOR_EPHEMERAL_APP_PATH: appBundle
})

export async function serverInputsKey(repoRoot, target) {
  const hash = createHash("sha256").update(`${target}\n`)
  for (const path of await serverInputs(repoRoot, target)) {
    hash.update(`${relative(repoRoot, path)}\n`)
    hash.update(await readFile(path))
  }
  return hash.digest("hex")
}

export const parseDefaultRouteInterface = (output) => /^\s*interface:\s*(\S+)/m.exec(output)?.[1]

const isTartInstalled = () =>
  new Promise((resolve) => {
    const child = spawn("tart", ["--version"], { stdio: "ignore" })
    child.on("error", () => resolve(false))
    child.on("exit", (code) => resolve(code === 0))
  })

const defaultRouteInterface = async () =>
  parseDefaultRouteInterface(await capture("/sbin/route", ["-n", "get", "default"]).catch(() => ""))

const cachedKey = (archiveRoot) =>
  readFile(join(archiveRoot, inputsKeyFile), "utf8").catch(() => "")

const buildServerArchive = async ({ repoRoot, archiveRoot, target }) => {
  const node = await ensureReleaseNode(repoRoot, target)
  await mkdir(archiveRoot, { recursive: true })
  const serverJs = join(archiveRoot, "server-js.tar.gz")
  try {
    await runScript(repoRoot, "scripts/release/package-server-js.sh", [serverJs])
    await runScript(
      repoRoot,
      "scripts/release/build-server-archive.sh",
      ["dev", archiveRoot, target],
      {
        CODEVISOR_PREBUILT_SERVER_JS: serverJs,
        CODEVISOR_RELEASE_NODE: join(node, "bin", "node"),
        npm_config_nodedir: node
      }
    )
  } finally {
    await rm(serverJs, { force: true })
  }
}

const ensureReleaseNode = async (repoRoot, target) => {
  const version = (await readFile(join(repoRoot, ".node-version"), "utf8")).trim()
  const name = `node-v${version}-${target}`
  const root = join(homedir(), ".codevisor-development", "artifacts", "node")
  const install = join(root, name)
  if (await pathExists(join(install, "bin", "node"))) return install

  await withArtifactLock(join(root, ".lock"), async () => {
    if (await pathExists(join(install, "bin", "node"))) return
    await installReleaseNode(root, name, `https://nodejs.org/dist/v${version}`)
  })
  return install
}

const installReleaseNode = async (root, name, base) => {
  const archive = Buffer.from(await download(`${base}/${name}.tar.gz`, "arrayBuffer"))
  const checksums = await download(`${base}/SHASUMS256.txt`, "text")
  const expected = checksums
    .split("\n")
    .find((line) => line.endsWith(`  ${name}.tar.gz`))
    ?.split(" ")[0]
  const actual = createHash("sha256").update(archive).digest("hex")
  if (expected !== actual) throw new Error(`${name}.tar.gz doesn't match its published SHA-256`)

  const staging = await mkdtemp(join(root, `${name}.pending-`))
  try {
    await writeFile(join(staging, "node.tar.gz"), archive)
    await runCommand("tar", ["-xzf", join(staging, "node.tar.gz"), "-C", staging])
    await rename(join(staging, name), join(root, name))
  } finally {
    await rm(staging, { recursive: true, force: true })
  }
}

const download = async (url, as) => {
  const response = await fetch(url)
  if (!response.ok) throw new Error(`${url} answered ${response.status}`)
  return response[as]()
}

const serverInputs = async (repoRoot, target) => {
  const packages = (await readdir(join(repoRoot, "packages"))).toSorted()
  const roots = [
    join(repoRoot, "apps/server/dist"),
    join(repoRoot, "patches"),
    ...packages.map((name) => join(repoRoot, "packages", name, "dist"))
  ]
  const singles = [
    join(repoRoot, "package.json"),
    join(repoRoot, "bun.lock"),
    join(repoRoot, ".node-version"),
    join(repoRoot, "apps/server/package.json"),
    join(repoRoot, "packages/net/native", target, "codevisor_net.node"),
    ...packages.map((name) => join(repoRoot, "packages", name, "package.json"))
  ]
  const files = [...(await existing(singles))]
  for (const root of roots) files.push(...(await filesUnder(root)))
  return files
}

const existing = async (paths) => {
  const present = await Promise.all(paths.map((path) => pathExists(path)))
  return paths.filter((_, index) => present[index])
}

const filesUnder = async (root) => {
  if (!(await pathExists(root))) return []

  const entries = await readdir(root, { recursive: true, withFileTypes: true })
  return entries
    .filter((entry) => entry.isFile())
    .map((entry) => join(entry.parentPath, entry.name))
    .toSorted()
}

const artifactFiles = async (repoRoot, archiveRoot) => {
  const files = new Map([["/install.sh", join(repoRoot, "apps/www/public/install.sh")]])
  for (const name of await readdir(archiveRoot).catch(() => [])) {
    const path = join(archiveRoot, name)
    if (archivePattern.test(name) && (await stat(path)).isFile()) files.set(`/${name}`, path)
  }
  return files
}

const pathnameOf = (url) => new URL(url ?? "/", "http://artifacts.invalid").pathname

const runScript = (repoRoot, script, arguments_, environment = {}) =>
  runCommand(join(repoRoot, script), arguments_, {
    cwd: repoRoot,
    env: { ...process.env, ...environment }
  })

const runCommand = async (command, arguments_, options = {}) => {
  const child = spawn(command, arguments_, { ...options, stdio: "inherit" })
  const result = await waitForExit(child)
  if (result.code !== 0) throw new Error(`${command} failed (${describeExit(result)})`)
}

const capture = async (command, arguments_) => {
  const child = spawn(command, arguments_, { stdio: ["ignore", "pipe", "ignore"] })
  let output = ""
  child.stdout.setEncoding("utf8")
  child.stdout.on("data", (chunk) => {
    output += chunk
  })
  const result = await waitForExit(child)
  if (result.code !== 0) throw new Error(`${command} failed (${describeExit(result)})`)
  return output
}
