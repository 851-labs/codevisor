import { X509Certificate } from "node:crypto"
import { execFileSync, spawn } from "node:child_process"
import { cp, mkdir, readFile, rm, writeFile } from "node:fs/promises"
import { join, resolve } from "node:path"
import process from "node:process"

import { describeExit, waitForExit } from "./dev-shared.mjs"

/// Host-side tooling the dev runner shells out to: command runners, the
/// per-worktree app icon, browser extension icons, signing identities, and
/// the surgical termination of a previously launched dev app.

export function makeCommandRunner(repoRoot) {
  function run(command, arguments_, cwd = repoRoot) {
    console.log(`\n$ ${command} ${arguments_.join(" ")}`)
    const child = spawn(command, arguments_, { cwd, env: process.env, stdio: "inherit" })
    return waitForExit(child).then((result) => {
      if (result.code === 0) return
      throw new Error(`${command} failed (${describeExit(result)})`)
    })
  }

  function capture(command, arguments_) {
    const child = spawn(command, arguments_, {
      cwd: repoRoot,
      env: process.env,
      stdio: ["ignore", "pipe", "inherit"]
    })
    let output = ""
    child.stdout.setEncoding("utf8")
    child.stdout.on("data", (chunk) => {
      output += chunk
    })
    return waitForExit(child).then((result) => {
      if (result.code === 0) return output
      throw new Error(`${command} failed (${describeExit(result)})`)
    })
  }

  return { capture, run }
}

// Locate apps/cloud/.dev.vars: this worktree first, then the main clone (via
// git's common dir), so per-developer cloud config is created once and shared
// by every worktree — including app-created ones. Returns {} when absent or
// git is unavailable; the cloud runs fine on dev login alone.
export async function readCloudDevVariables(repoRoot) {
  const candidates = [join(repoRoot, "apps/cloud/.dev.vars")]
  try {
    const commonDir = execFileSync("git", ["rev-parse", "--git-common-dir"], {
      cwd: repoRoot,
      encoding: "utf8"
    }).trim()
    const mainRoot = resolve(repoRoot, commonDir, "..")
    if (mainRoot !== repoRoot) candidates.push(join(mainRoot, "apps/cloud/.dev.vars"))
  } catch {
    // Not a git checkout (or git missing): worktree-local file only.
  }
  for (const candidate of candidates) {
    let content
    try {
      content = await readFile(candidate, "utf8")
    } catch {
      continue
    }
    const variables = {}
    for (const line of content.split("\n")) {
      const trimmed = line.trim()
      if (trimmed === "" || trimmed.startsWith("#")) continue
      const separator = trimmed.indexOf("=")
      if (separator === -1) continue
      variables[trimmed.slice(0, separator).trim()] = trimmed
        .slice(separator + 1)
        .trim()
        .replace(/^"(.*)"$/, "$1")
    }
    return variables
  }
  return {}
}

export async function createDevelopmentAppIcon(repoRoot, developmentIconColor) {
  const templateDirectory = join(
    repoRoot,
    "apps",
    "macos",
    "Codevisor",
    "Resources",
    "AppIconDev.icon"
  )
  const generatedDirectory = join(
    repoRoot,
    "apps",
    "macos",
    "Codevisor",
    "Resources",
    "AppIconDevGenerated.icon"
  )
  await rm(generatedDirectory, { recursive: true, force: true })
  await mkdir(join(generatedDirectory, "Assets"), { recursive: true })
  const manifest = JSON.parse(await readFile(join(templateDirectory, "icon.json"), "utf8"))
  manifest.fill = { "automatic-gradient": developmentIconColor.composer }
  await writeFile(join(generatedDirectory, "icon.json"), `${JSON.stringify(manifest, null, 2)}\n`)
  await cp(
    join(templateDirectory, "Assets", "icon-v2.svg"),
    join(generatedDirectory, "Assets", "icon-v2.svg")
  )
  return generatedDirectory
}

export async function createDevelopmentBrowserExtensionIcons({
  appName,
  derivedDataPath,
  layout,
  run
}) {
  const iconsetDirectory = join(layout.build.generated, "BrowserExtensionDev.iconset")
  const compiledIcon = join(
    derivedDataPath,
    "Build",
    "Products",
    "Debug",
    `${appName}.app`,
    "Contents",
    "Resources",
    "AppIconDevGenerated.icns"
  )
  await rm(iconsetDirectory, { recursive: true, force: true })
  await run("iconutil", ["--convert", "iconset", "--output", iconsetDirectory, compiledIcon])
  return iconsetDirectory
}

export function terminateExactDevelopmentApp(executable) {
  const pattern = `^${escapeRegularExpression(executable)}$`
  let processIDs
  try {
    processIDs = execFileSync("/usr/bin/pgrep", ["-f", pattern], { encoding: "utf8" })
      .trim()
      .split(/\s+/)
      .filter(Boolean)
      .map(Number)
  } catch (error) {
    if (error?.status === 1) return
    throw error
  }

  for (const processID of processIDs) {
    let command
    try {
      command = execFileSync("/bin/ps", ["-p", String(processID), "-o", "command="], {
        encoding: "utf8"
      }).trim()
    } catch (error) {
      if (error?.status === 1) continue
      throw error
    }
    if (command !== executable) continue
    try {
      process.kill(processID, "SIGTERM")
    } catch (error) {
      if (error?.code !== "ESRCH") throw error
    }
  }
}

function escapeRegularExpression(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&")
}

export async function resolveDevelopmentSigningArguments(capture) {
  const identities = await capture("security", ["find-identity", "-v", "-p", "codesigning"])
  const match = identities.match(/[0-9]+\)\s+([0-9A-F]+)\s+"(Apple Development:[^"]+)"/)
  if (match === null) {
    console.warn(
      "\nNo Apple Development signing identity was found. This build will be ad-hoc signed, so macOS may require Accessibility permission again after a rebuild."
    )
    return []
  }
  const [, hash, identity] = match
  const certificate = await capture("security", ["find-certificate", "-c", identity, "-p"])
  const team = new X509Certificate(certificate).toLegacyObject().subject.OU
  if (typeof team !== "string" || team.length === 0) {
    console.warn(
      `\nThe ${identity} certificate has no signing team identifier. This build will be ad-hoc signed, so macOS may require Accessibility permission again after a rebuild.`
    )
    return []
  }
  console.log(`Using stable development signing identity ${hash} (${team})`)
  return [
    `CODE_SIGN_IDENTITY=${hash}`,
    `DEVELOPMENT_TEAM=${team}`,
    "CODE_SIGN_STYLE=Manual",
    "PROVISIONING_PROFILE_SPECIFIER="
  ]
}
