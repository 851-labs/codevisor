#!/usr/bin/env node
// Build the self-contained diagnostic app (the rig executable's `probe` subcommand), including the pinned WebRTC framework.
import { spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { cpSync, existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const root = dirname(dirname(dirname(dirname(fileURLToPath(import.meta.url)))))
const packagePath = join(root, "apps/screen-sharing-rig")
const args = process.argv.slice(2)
const releaseIndex = args.indexOf("--release")
const configuration = releaseIndex >= 0 ? "release" : "debug"
if (releaseIndex >= 0) args.splice(releaseIndex, 1)
const instanceIndex = args.indexOf("--instance")
let instance = ""
if (instanceIndex >= 0) {
  instance = args[instanceIndex + 1] ?? ""
  if (!/^[a-z0-9-]{1,32}$/.test(instance))
    throw new Error("--instance needs a short lowercase name")
  args.splice(instanceIndex, 2)
}
const app = join(root, `tmp/screen-sharing/ScreenSharingProbe${instance ? `-${instance}` : ""}.app`)
// Separate installed identities prevent Launch Services and TCC from resolving
// one diagnostic instance to another worktree's or instance's executable.
// Ad-hoc rebuilds still change the code requirement and may need a new grant.
const worktreeID = createHash("sha256").update(root).digest("hex").slice(0, 12)
const bundleID = `com.codevisor.ScreenSharingProbe.w${worktreeID}.${instance || "default"}`
const displayName = `Screen Sharing Probe${instance ? ` (${instance})` : ""}`

function run(command: string, args: string[], capture = false): string {
  const result = spawnSync(command, args, {
    cwd: root,
    stdio: capture ? ["inherit", "pipe", "inherit"] : "inherit",
    encoding: "utf8"
  })
  if (result.error) throw result.error
  if (result.status !== 0) process.exit(result.status ?? 1)
  return result.stdout?.trim()
}

if (process.platform !== "darwin") throw new Error("The Screen Sharing probe requires macOS.")
if (existsSync(app)) {
  const owners = spawnSync(
    "/usr/sbin/lsof",
    ["-t", join(app, "Contents/MacOS/screen-sharing-probe")],
    {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"]
    }
  )
  if (owners.error) throw owners.error
  if (owners.status === 0 && owners.stdout.trim()) {
    throw new Error("This probe is running. Stop it or use --instance NAME before rebuilding.")
  }
}
run("swift", [
  "build",
  "--package-path",
  packagePath,
  "--configuration",
  configuration,
  "--product",
  "screen-sharing-rig"
])
const bin = run(
  "swift",
  ["build", "--package-path", packagePath, "--configuration", configuration, "--show-bin-path"],
  true
)
rmSync(app, { recursive: true, force: true })
const contents = join(app, "Contents")
const executable = join(contents, "MacOS/screen-sharing-probe")
mkdirSync(join(contents, "MacOS"), { recursive: true })
mkdirSync(join(contents, "Frameworks"), { recursive: true })
mkdirSync(join(contents, "Resources"), { recursive: true })
cpSync(join(bin, "screen-sharing-rig"), executable)
cpSync(join(bin, "WebRTC.framework"), join(contents, "Frameworks/WebRTC.framework"), {
  recursive: true,
  verbatimSymlinks: true
})
cpSync(
  join(bin, "CodevisorKit_ScreenSharingWebRTC.bundle"),
  join(contents, "Resources/CodevisorKit_ScreenSharingWebRTC.bundle"),
  {
    recursive: true
  }
)
writeFileSync(
  join(contents, "Info.plist"),
  `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>${bundleID}</string>
<key>CFBundleName</key><string>${displayName}</string>
<key>CFBundleDisplayName</key><string>${displayName}</string>
<key>CFBundleExecutable</key><string>screen-sharing-probe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleVersion</key><string>1</string>
<key>CodevisorProbeBuildConfiguration</key><string>${configuration}</string>
<key>LSMinimumSystemVersion</key><string>26.0</string>
<key>NSHighResolutionCapable</key><true/>
<key>NSScreenCaptureUsageDescription</key><string>Capture the display you select for a native Screen Sharing diagnostic.</string>
<key>NSLocalNetworkUsageDescription</key><string>Connect to the other Mac in your Screen Sharing diagnostic.</string>
</dict></plist>
`
)
run("install_name_tool", ["-add_rpath", "@executable_path/../Frameworks", executable])
run("codesign", ["--force", "--sign", "-", join(contents, "Frameworks/WebRTC.framework")])
run("codesign", ["--force", "--sign", "-", app])
process.stdout.write(`Built ${app}\n`)
if (!args.includes("--build-only")) run(executable, ["probe", ...args])
