#!/usr/bin/env node
import { spawnSync } from "node:child_process"
// An isolated, pinned source recipe. Does not change the reference submodule,
// installed SwiftPM artifact, Xcode selection, or any published release.
import { createHash } from "node:crypto"
import {
  cpSync,
  existsSync,
  mkdirSync,
  readFileSync,
  readdirSync,
  rmSync,
  writeFileSync
} from "node:fs"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

const repoRoot = dirname(dirname(fileURLToPath(import.meta.url)))
const lockBytes = readFileSync(new URL("./webrtc-build.lock.json", import.meta.url))
const lock = JSON.parse(lockBytes)
const recipeSHA256 = createHash("sha256")
  .update(readFileSync(fileURLToPath(import.meta.url)))
  .digest("hex")
const stamp = createHash("sha256").update(lockBytes).update(recipeSHA256).digest("hex").slice(0, 16)
const workspace = join(repoRoot, "tmp/webrtc-source", stamp)
const source = join(workspace, "src")
const depot = join(workspace, "depot_tools")
const output = join(workspace, "artifacts")
const framework = join(output, "WebRTC.xcframework")
const environment = {
  ...process.env,
  PATH: `${depot}:${process.env.PATH}`,
  DEPOT_TOOLS_UPDATE: "0",
  DEPOT_TOOLS_METRICS: "0"
}
const variants = [
  { name: "macos-arm64", cpu: "arm64", os: "mac", target: "mac_framework_objc" },
  { name: "macos-x64", cpu: "x64", os: "mac", target: "mac_framework_objc" },
  {
    name: "ios-arm64-device",
    cpu: "arm64",
    os: "ios",
    target: "framework_objc",
    platform: "device"
  },
  {
    name: "ios-arm64-simulator",
    cpu: "arm64",
    os: "ios",
    target: "framework_objc",
    platform: "simulator"
  },
  {
    name: "ios-x64-simulator",
    cpu: "x64",
    os: "ios",
    target: "framework_objc",
    platform: "simulator"
  }
]

function run(command, args, cwd = workspace, capture = false) {
  const result = spawnSync(command, args, {
    cwd,
    env: environment,
    encoding: "utf8",
    stdio: capture ? ["ignore", "pipe", "inherit"] : "inherit",
    maxBuffer: 32 * 1024 * 1024
  })
  if (result.error) throw result.error
  if (result.status !== 0) throw new Error(`${command} failed (${result.status})`)
  return result.stdout?.trim()
}

function argumentsFor(variant) {
  return [
    ...lock.gnArguments,
    `target_cpu="${variant.cpu}"`,
    `target_os="${variant.os}"`,
    ...(variant.os === "ios"
      ? [
          `target_environment="${variant.platform}"`,
          'ios_deployment_target="12.0"',
          "ios_enable_code_signing=false"
        ]
      : [])
  ].join(" ")
}

function checkout(directory, url, revision) {
  if (!existsSync(directory)) {
    mkdirSync(directory)
    run("git", ["init", "--quiet"], directory)
    run("git", ["remote", "add", "origin", url], directory)
  }
  // Never discard a source edit when resuming a failed build.
  if (existsSync(join(directory, ".git/HEAD"))) {
    const status = run("git", ["status", "--porcelain", "--untracked-files=no"], directory, true)
    if (status) throw new Error(`Source checkout has edits: ${directory}`)
  }
  if (run("git", ["remote", "get-url", "origin"], directory, true) !== url) {
    throw new Error(`Unexpected source remote in ${directory}`)
  }
  run("git", ["fetch", "--depth=1", "origin", revision], directory)
  run("git", ["checkout", "--detach", revision], directory)
  const actual = run("git", ["rev-parse", "HEAD"], directory, true)
  if (actual !== revision) throw new Error(`Unexpected source revision in ${directory}`)
}

function notices(platform, target, builds) {
  const directory = join(output, `notices-${platform}`)
  mkdirSync(directory, { recursive: true })
  run(
    "vpython3",
    [
      join(source, "tools_webrtc/libs/generate_licenses.py"),
      "--target",
      `//sdk:${target}`,
      directory,
      ...builds.map((name) => join(source, "out", name))
    ],
    source
  )
  const text = readFileSync(join(directory, "LICENSE.md"), "utf8")
  if (!text.includes("# webrtc") || text.length < 1000)
    throw new Error("Generated notices are incomplete")
  return text
}

function stage(identifier, builds, licenseText) {
  const directory = join(output, "staging", identifier)
  mkdirSync(directory, { recursive: true })
  const staged = join(directory, "WebRTC.framework")
  const dsym = join(directory, "WebRTC.dSYM")
  const paths = builds.map((name) => join(source, "out", name))
  cpSync(join(paths[0], "WebRTC.framework"), staged, { recursive: true, verbatimSymlinks: true })
  cpSync(join(paths[0], "WebRTC.dSYM"), dsym, { recursive: true, verbatimSymlinks: true })
  const mac = identifier.startsWith("macos")
  const resources = mac ? join(staged, "Versions/A/Resources") : staged
  if (mac) {
    // M152 leaves public macOS headers in gen/ and nests the privacy manifest.
    const headers = join(paths[0], "gen/sdk/WebRTC.framework/Headers")
    for (const file of readdirSync(headers).filter((file) => file.endsWith(".h"))) {
      cpSync(join(headers, file), join(staged, "Versions/A/Headers", file))
    }
    const nested = join(staged, "Versions/A/Versions")
    const manifest = join(nested, "A/Resources/PrivacyInfo.xcprivacy")
    if (existsSync(manifest)) {
      cpSync(manifest, join(resources, "PrivacyInfo.xcprivacy"))
      rmSync(nested, { recursive: true })
    }
  }
  if (!existsSync(join(resources, "PrivacyInfo.xcprivacy")))
    throw new Error(`Missing privacy manifest: ${identifier}`)
  writeFileSync(join(resources, "WebRTC-ThirdPartyNotices.md"), licenseText)
  if (paths.length > 1) {
    run("lipo", [
      "-create",
      ...paths.map((path) => join(path, "WebRTC.framework/WebRTC")),
      "-output",
      mac ? join(staged, "Versions/A/WebRTC") : join(staged, "WebRTC")
    ])
    run("lipo", [
      "-create",
      ...paths.map((path) => join(path, "WebRTC.dSYM/Contents/Resources/DWARF/WebRTC")),
      "-output",
      join(dsym, "Contents/Resources/DWARF/WebRTC")
    ])
    for (const path of paths.slice(1)) {
      const relocations = join(path, "WebRTC.dSYM/Contents/Resources/Relocations")
      if (existsSync(relocations))
        cpSync(relocations, join(dsym, "Contents/Resources/Relocations"), { recursive: true })
    }
  }
  run("codesign", ["--force", "--sign", "-", staged])
  run("codesign", ["--verify", "--strict", staged])
  return ["-framework", staged, "-debug-symbols", dsym]
}

function build() {
  if (process.platform !== "darwin") throw new Error("The WebRTC artifact requires macOS")
  // Validate tools before fetching gigabytes of sources. Respect DEVELOPER_DIR;
  // this script never changes the user's global xcode-select setting.
  const xcode = run("xcodebuild", ["-version"], repoRoot, true)
  const python = run("python3", ["--version"], repoRoot, true)
  if (!xcode.split("\n").includes(`Xcode ${lock.xcodeVersion}`)) {
    throw new Error(
      `Select Xcode ${lock.xcodeVersion} with DEVELOPER_DIR; found ${xcode.split("\n")[0]}`
    )
  }
  if (python !== `Python ${lock.pythonVersion}`)
    throw new Error(`Python ${lock.pythonVersion} is required; found ${python}`)
  mkdirSync(workspace, { recursive: true })
  const buildLock = join(workspace, ".building")
  mkdirSync(buildLock) // Refuse concurrent builds of this exact artifact.
  try {
    if (existsSync(output))
      throw new Error(
        `Preserve or remove the prior artifact directory before rebuilding: ${output}`
      )
    checkout(
      depot,
      "https://chromium.googlesource.com/chromium/tools/depot_tools.git",
      lock.depotToolsRevision
    )
    // Disabling depot_tools updates also skips gclient's implicit bootstrap.
    // Initialize its pinned tools without advancing the checkout revision.
    run(join(depot, "ensure_bootstrap"), [], depot)
    checkout(source, "https://webrtc.googlesource.com/src.git", lock.sourceRevision)
    writeFileSync(
      join(workspace, ".gclient"),
      `solutions = [{"name": "src", "url": "https://webrtc.googlesource.com/src.git", "managed": False, "deps_file": "DEPS", "custom_deps": {}}]\ntarget_os = ["ios", "mac"]\n`
    )
    run("gclient", [
      "sync",
      "--no-history",
      "--nohooks",
      "--revision",
      `src@${lock.sourceRevision}`
    ])
    run("gclient", ["runhooks"])
    mkdirSync(output)
    writeFileSync(
      join(output, "revisions.txt"),
      run("gclient", ["revinfo", "--actual"], workspace, true) + "\n"
    )
    for (const variant of variants) {
      const directory = join(source, "out", variant.name)
      run("gn", ["gen", directory, `--args=${argumentsFor(variant)}`], source)
      writeFileSync(
        join(output, `${variant.name}-gn-args.txt`),
        run("gn", ["args", directory, "--list"], source, true) + "\n"
      )
      run("ninja", ["-C", directory, variant.target], source)
    }
    const macNotices = notices("macos", "mac_framework_objc", ["macos-arm64", "macos-x64"])
    const iosNotices = notices("ios", "framework_objc", [
      "ios-arm64-device",
      "ios-arm64-simulator",
      "ios-x64-simulator"
    ])
    const slices = [
      ...stage("macos-arm64_x86_64", ["macos-arm64", "macos-x64"], macNotices),
      ...stage("ios-arm64", ["ios-arm64-device"], iosNotices),
      ...stage(
        "ios-arm64_x86_64-simulator",
        ["ios-arm64-simulator", "ios-x64-simulator"],
        iosNotices
      )
    ]
    run("xcodebuild", ["-create-xcframework", ...slices, "-output", framework])
    cpSync(join(source, "LICENSE"), join(framework, "LICENSE"))
    cpSync(join(source, "PATENTS"), join(framework, "PATENTS"))
    const archive = join(output, "WebRTC.xcframework.zip")
    run("ditto", ["-c", "-k", "--sequesterRsrc", "--keepParent", framework, archive])
    writeFileSync(
      join(output, "manifest.json"),
      JSON.stringify(
        {
          ...lock,
          recipeStamp: stamp,
          recipeSHA256,
          xcode,
          python,
          sha256: createHash("sha256").update(readFileSync(archive)).digest("hex"),
          archive: "WebRTC.xcframework.zip"
        },
        null,
        2
      ) + "\n"
    )
    process.stdout.write(
      `Artifact and source records: ${output}\nNo package pin or published artifact was changed.\n`
    )
  } finally {
    rmSync(buildLock, { recursive: true })
  }
}

const args = process.argv.slice(2)
if (args.length === 1 && args[0] === "--plan") {
  process.stdout.write(
    JSON.stringify(
      {
        ...lock,
        workspace,
        output,
        builds: variants.map((variant) =>
          Object.assign({}, variant, { gnArguments: argumentsFor(variant) })
        )
      },
      null,
      2
    )
  )
} else if (args.length === 0) {
  build()
} else {
  throw new Error("Usage: node scripts/build-webrtc.mjs [--plan]")
}
