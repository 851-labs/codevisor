import { spawnSync } from "node:child_process"
import { readdir } from "node:fs/promises"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { chromiumHelperSuffixes } from "../chromium-artifact.mjs"

const storageName = "CodevisorBrowserStorage.dylib"
const storageLoadPath = `@rpath/${storageName}`

function execute(command, args) {
  const result = spawnSync(command, args, { encoding: "utf8" })
  if (result.error) throw result.error
  const output = (result.stdout ?? "") + (result.stderr ?? "")
  if (result.status !== 0) throw new Error(`${command} failed: ${output.trim()}`)
  return output
}

export async function embeddedLibraries(app) {
  const frameworks = join(app, "Contents/Frameworks")
  // Do not follow aliases or re-sign code inside an already sealed framework.
  return (await readdir(frameworks, { withFileTypes: true }))
    .filter((entry) => entry.isFile() && entry.name.endsWith(".dylib"))
    .map((entry) => join(frameworks, entry.name))
    .sort()
}

export async function signEmbeddedLibraries(app, identity, run = execute) {
  if (!identity) throw new Error("An explicit signing identity is required (use - for ad-hoc).")
  for (const library of await embeddedLibraries(app)) {
    run("codesign", [
      "--force",
      "--sign",
      identity,
      "--options",
      "runtime",
      identity === "-" ? "--timestamp=none" : "--timestamp",
      library
    ])
  }
}

function browserExecutables(app) {
  return [
    join(app, "Contents/MacOS/Codevisor"),
    ...chromiumHelperSuffixes.map((suffix) => {
      const name = `Codevisor Browser Helper${suffix}`
      return join(app, "Contents/Frameworks", `${name}.app`, "Contents/MacOS", name)
    })
  ]
}

function architecturesOf(binary, run) {
  return run("lipo", ["-archs", binary]).trim().split(/\s+/)
}

export function verifyBrowserLinkage(app, architectures, run = execute) {
  if (architectures.length === 0) throw new Error("Expected browser architectures are required.")
  const library = join(app, "Contents/Frameworks", storageName)
  const executables = browserExecutables(app)
  for (const binary of [library, ...executables]) {
    const actual = architecturesOf(binary, run)
    for (const arch of architectures) {
      if (!actual.includes(arch)) throw new Error(`${binary} is missing ${arch}.`)
      if (binary === library) continue
      // dyld_info accepts helper names containing parentheses, unlike otool's
      // archive(member) filename parser. Reject weak or delayed dependencies:
      // interposition requires the library to be loaded at process startup.
      const dependencies = run("xcrun", ["dyld_info", "-arch", arch, "-dependents", binary])
      if (!dependencies.split("\n").some((line) => line.trim() === storageLoadPath)) {
        throw new Error(`${binary} (${arch}) must load ${storageLoadPath} at startup.`)
      }
    }
  }
}

export async function verifyBrowserDistribution(app, architectures, run = execute) {
  verifyBrowserLinkage(app, architectures, run)
  const executables = browserExecutables(app)
  const mainDetails = run("codesign", ["-d", "--verbose=4", executables[0]])
  const team = /^TeamIdentifier=([A-Z0-9]+)$/m.exec(mainDetails)?.[1]
  if (!team) throw new Error("The release app must have a signing Team ID.")
  // Developer ID Application, issued by Apple's Developer ID intermediate,
  // with the same team as the app. Strict verification alone accepts ad-hoc.
  const requirement = `=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists and certificate leaf[field.1.2.840.113635.100.6.1.13] exists and certificate leaf[subject.OU] = "${team}"`
  for (const binary of [...executables, ...(await embeddedLibraries(app))]) {
    run("codesign", ["--verify", "--strict", "--all-architectures", "-R", requirement, binary])
    // A universal dylib remains universal in the split apps. Check every slice,
    // including those not used by this app variant: Apple scans them all.
    for (const arch of architecturesOf(binary, run)) {
      const details = run("codesign", ["-d", "--verbose=4", "--arch", arch, binary])
      if (!/^Timestamp=.+$/m.test(details) || !/flags=.*\bruntime\b/.test(details)) {
        throw new Error(`${binary} (${arch}) requires a secure timestamp and hardened runtime.`)
      }
    }
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const [operation, app, ...args] = process.argv.slice(2)
  if (!app)
    throw new Error(
      "Usage: macos-browser-artifact.mjs <linkage|distribution|sign-libraries> <app> <architectures...|identity>"
    )
  if (operation === "sign-libraries" && args.length === 1) {
    await signEmbeddedLibraries(app, args[0])
  } else if (operation === "linkage") {
    verifyBrowserLinkage(app, args)
  } else if (operation === "distribution") {
    await verifyBrowserDistribution(app, args)
  } else {
    throw new Error(`Unknown browser artifact operation: ${operation}`)
  }
  console.log(`Browser artifact ${operation} passed.`)
}
