#!/usr/bin/env node
// `bun run vnc:interop`: layer L3 of docs/plans/vnc-validation.md. Builds (or
// reuses) the pinned TigerVNC image, starts it on an OS-chosen loopback port,
// waits for the RFB greeting, runs the Swift interop suites against it, and
// always removes the container. Exits non-zero unless the suites ran, none
// were skipped, and all passed.
import { spawn, spawnSync } from "node:child_process"
import { readFileSync } from "node:fs"
import { connect } from "node:net"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import {
  checkTestRun,
  defaults,
  imageTag,
  interopEnvironment,
  parseDockerPort,
  parseInteropArguments
} from "./vnc-interop-lib.mjs"

const root = dirname(dirname(dirname(dirname(fileURLToPath(import.meta.url)))))
const context = join(root, "apps/screen-sharing-rig/scripts/vnc-interop")
const usage = `Usage: bun run vnc:interop [--filter SWIFT_TEST_FILTER] [--geometry WxH] [--keep]

Runs the Swift interop suites (default filter "${defaults.filter}") against a pinned TigerVNC
Xvnc container. --keep leaves the container running and prints its VNC_TEST_* environment.
Needs a running Docker (OrbStack or Colima).
`

let options
try {
  options = parseInteropArguments(process.argv.slice(2))
} catch (error) {
  process.stderr.write(`${error.message}\n\n${usage}`)
  process.exit(2)
}
if (options.help) {
  process.stdout.write(usage)
  process.exit(0)
}

const docker = (args, { allowFailure = false } = {}) => {
  const result = spawnSync("docker", args, { encoding: "utf8" })
  if (result.status !== 0 && !allowFailure) {
    throw new Error(`docker ${args.join(" ")} failed: ${result.stderr || result.stdout}`)
  }
  return result
}

if (docker(["info", "--format", "{{.ServerVersion}}"], { allowFailure: true }).status !== 0) {
  process.stderr.write(
    "vnc:interop needs a running Docker daemon (start OrbStack: `orbctl start`).\n"
  )
  process.exit(3)
}

const tag = imageTag({
  Dockerfile: readFileSync(join(context, "Dockerfile"), "utf8"),
  "entrypoint.sh": readFileSync(join(context, "entrypoint.sh"), "utf8")
})
if (docker(["image", "inspect", tag], { allowFailure: true }).status !== 0) {
  process.stdout.write(`Building ${tag}…\n`)
  docker(["build", "-q", "-t", tag, context])
}

const container = docker([
  "run",
  "-d",
  "--rm",
  "-p",
  `127.0.0.1::${defaults.containerPort}`,
  "-e",
  `GEOMETRY=${options.geometry}`,
  "-e",
  `PASSWORD=${defaults.password}`,
  "-e",
  `ROOT_COLOR=#${defaults.rootColor}`,
  tag
]).stdout.trim()
const cleanup = () => {
  if (!options.keep) docker(["rm", "-f", container], { allowFailure: true })
}
for (const signal of ["SIGINT", "SIGTERM"]) {
  process.on(signal, () => {
    cleanup()
    process.exit(130)
  })
}

let status = 1
try {
  const port = parseDockerPort(docker(["port", container, `${defaults.containerPort}/tcp`]).stdout)
  await waitForGreeting(port)
  // Xvnc answers before the entrypoint has painted the known desktop; wait for it too.
  await waitForReady(container)
  const environment = interopEnvironment({
    port,
    password: defaults.password,
    geometry: options.geometry,
    rootColor: defaults.rootColor
  })
  process.stdout.write(`TigerVNC on 127.0.0.1:${port} (${tag})\n`)
  if (options.keep) {
    for (const [key, value] of Object.entries(environment))
      process.stdout.write(`export ${key}=${value}\n`)
  }
  const output = await runSwiftTests(options.filter, environment)
  const verdict = checkTestRun(output)
  process.stdout.write(
    `\nvnc:interop: ${verdict.ok ? "PASS" : "FAIL"} — ${verdict.ran} test(s) ran, ${verdict.skipped} skipped` +
      (verdict.problems.length ? ` (${verdict.problems.join("; ")})` : "") +
      "\n"
  )
  status = verdict.ok ? 0 : 1
} catch (error) {
  process.stderr.write(`vnc:interop: ${error.message}\n`)
} finally {
  cleanup()
}
process.exit(status)

/// The entrypoint prints "vnc-interop: ready" once the root colour and pointer are set.
async function waitForReady(container, deadlineMs = 30_000) {
  const started = Date.now()
  while (Date.now() - started < deadlineMs) {
    if (docker(["logs", container], { allowFailure: true }).stdout.includes("vnc-interop: ready"))
      return
    // oxlint-disable-next-line no-await-in-loop
    await new Promise((resolve) => setTimeout(resolve, 200))
  }
  throw new Error(`The interop desktop wasn't ready within ${deadlineMs / 1000} s`)
}

/// Real I/O: connect until the server's 12-byte "RFB 003.00x\n" greeting arrives.
async function waitForGreeting(port, deadlineMs = 30_000) {
  const started = Date.now()
  while (Date.now() - started < deadlineMs) {
    // Retries are sequential by design: each attempt waits for the previous one.
    // oxlint-disable-next-line no-await-in-loop
    const greeting = await new Promise((resolve) => {
      const socket = connect({ host: "127.0.0.1", port })
      let data = ""
      const finish = (value) => {
        socket.destroy()
        resolve(value)
      }
      socket.setTimeout(2_000, () => finish(null))
      socket.on("data", (chunk) => {
        data += chunk.toString("latin1")
        if (data.length >= 12) finish(data)
      })
      socket.on("error", () => finish(null))
      socket.on("close", () => finish(null))
    })
    if (greeting?.startsWith("RFB ")) return
    // oxlint-disable-next-line no-await-in-loop
    await new Promise((resolve) => setTimeout(resolve, 250))
  }
  throw new Error(`No RFB greeting on 127.0.0.1:${port} within ${deadlineMs / 1000} s`)
}

function runSwiftTests(filter, environment) {
  return new Promise((resolve) => {
    const child = spawn(
      "swift",
      ["test", "--package-path", join(root, "packages/swift"), "--filter", filter],
      {
        env: { ...process.env, ...environment },
        stdio: ["ignore", "pipe", "pipe"]
      }
    )
    let output = ""
    for (const stream of [child.stdout, child.stderr]) {
      stream.on("data", (chunk) => {
        output += chunk
        process.stdout.write(chunk)
      })
    }
    child.on("close", () => resolve(output))
  })
}
