import { execFile } from "node:child_process"
import { mkdir, mkdtemp, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join, resolve } from "node:path"
import process from "node:process"
import { parseArgs, promisify } from "node:util"

const execute = promisify(execFile)
const image = "codevisor-bento-linux"
const label = "codevisor-bento=1"
const ghostty = "/Applications/Ghostty.app"
const installedBinary = "/home/you/.local/bin/codevisor"
const waitSeconds = 120
const settleSeconds = 4

const usage = `Usage: bun run bento:linux-install [--output directory]

Opens a new Ghostty window (a separate Ghostty instance, so existing windows are untouched) whose
command is a throwaway Ubuntu container (user you, host vps) and whose startup input runs the real
"curl -fsSL https://www.codevisor.dev/install.sh | sh". Setup is skipped with CODEVISOR_NO_SETUP=1
in the image, so no sign-in code is shown. The window is captured without a shadow as
linux-install-dark@2x.png (Ghostty's default theme is dark), then the container, the Ghostty
instance, and the image are removed.`

const { values: options } = parseArgs({
  options: {
    output: { type: "string", default: "tmp/bento-shots" },
    help: { type: "boolean", default: false }
  }
})
if (options.help) {
  console.log(usage)
  process.exit(0)
}

const output = resolve(options.output)
await mkdir(output, { recursive: true })
const scratch = await mkdtemp(join(tmpdir(), "codevisor-linux-install-"))
const before = await ghosttyProcesses()
try {
  await buildImage()
  const config = join(scratch, "ghostty.conf")
  await writeFile(config, ghosttyConfig(await dockerPath()))
  await execute("open", ["-na", ghostty, "--args", `--config-file=${config}`])
  const container = await waitFor("the container to start", async () => (await containers())[0])
  await waitFor("the installer to finish", async () => {
    const installed = await succeeds("docker", ["exec", container, "test", "-x", installedBinary])
    return installed && !(await succeeds("docker", ["exec", container, "pgrep", "-x", "sh"]))
  })
  await sleep(settleSeconds)
  const launched = (await ghosttyProcesses()).filter((pid) => !before.includes(pid))
  const window = await windowOf(launched, scratch)
  const file = join(output, "linux-install-dark@2x.png")
  await execute("/usr/sbin/screencapture", ["-x", "-o", "-l", window, file])
  console.log(file)
} finally {
  const leftover = await containers()
  if (leftover.length > 0) await execute("docker", ["rm", "--force", ...leftover])
  const launched = (await ghosttyProcesses()).filter((pid) => !before.includes(pid))
  if (launched.length > 0) await execute("kill", ["-TERM", ...launched]).catch(() => {})
  await execute("docker", ["image", "rm", image]).catch(() => {})
  await rm(scratch, { recursive: true, force: true })
}

async function buildImage() {
  const context = join(scratch, "image")
  await mkdir(context, { recursive: true })
  await writeFile(
    join(context, "Dockerfile"),
    [
      "FROM ubuntu:24.04",
      "RUN apt-get update && apt-get install -y --no-install-recommends curl ca-certificates \\",
      "  && rm -rf /var/lib/apt/lists/* && useradd --create-home --shell /bin/bash you",
      "USER you",
      "WORKDIR /home/you",
      "ENV CODEVISOR_NO_SETUP=1",
      ""
    ].join("\n")
  )
  await execute("docker", ["build", "--quiet", "--tag", image, context])
}

function ghosttyConfig(docker) {
  return [
    "window-width = 100",
    "window-height = 28",
    `command = ${docker} run --rm -it --hostname vps -e TERM=xterm-256color --label ${label} ${image}`,
    String.raw`input = raw:clear; sleep ${settleSeconds}; clear\ncurl -fsSL https://www.codevisor.dev/install.sh | sh\n`,
    ""
  ].join("\n")
}

async function dockerPath() {
  return (await execute("which", ["docker"])).stdout.trim()
}

async function containers() {
  const { stdout } = await execute("docker", ["ps", "-aq", "--filter", `label=${label}`])
  return stdout.split("\n").filter((id) => id !== "")
}

async function ghosttyProcesses() {
  const { stdout } = await execute("pgrep", ["-f", `${ghostty}/Contents/MacOS/ghostty`]).catch(
    () => ({ stdout: "" })
  )
  return stdout.split("\n").filter((pid) => pid !== "")
}

async function windowOf(pids, directory) {
  const script = join(directory, "window.swift")
  await writeFile(
    script,
    [
      "import AppKit",
      "let pids = Set(CommandLine.arguments.dropFirst().compactMap { Int($0) })",
      "for pid in pids { NSRunningApplication(processIdentifier: pid_t(pid))?.activate(options: [.activateIgnoringOtherApps]) }",
      "Thread.sleep(forTimeInterval: 1)",
      "let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []",
      "for window in info where pids.contains(window[kCGWindowOwnerPID as String] as? Int ?? -1)",
      "  && (window[kCGWindowLayer as String] as? Int) == 0",
      '  && ((window[kCGWindowBounds as String] as? [String: Any])?["Height"] as? Double ?? 0) > 100 {',
      '  print(window[kCGWindowNumber as String] ?? "")',
      "}",
      ""
    ].join("\n")
  )
  const { stdout } = await execute("xcrun", ["swift", script, ...pids])
  const window = stdout.split("\n").find((id) => id !== "")
  if (window === undefined) throw new Error("The new Ghostty window was not found")
  return window
}

async function succeeds(command, args) {
  return execute(command, args).then(
    () => true,
    () => false
  )
}

async function waitFor(what, check) {
  for (let elapsed = 0; elapsed < waitSeconds; elapsed++) {
    const result = await check()
    if (result) return result
    await sleep(1)
  }
  throw new Error(`Timed out waiting for ${what}`)
}

function sleep(seconds) {
  return new Promise((wake) => setTimeout(wake, seconds * 1000))
}
