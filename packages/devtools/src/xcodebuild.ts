import { type ChildProcess, spawn, spawnSync, type StdioOptions } from "node:child_process"
import { mkdir } from "node:fs/promises"
import { join, resolve as resolvePath } from "node:path"

import { describeExit, waitForExit } from "./child-processes.ts"
import { type DevelopmentLayout, developmentLayout } from "./dev-layout.ts"
import { prepareSwiftArtifacts } from "./swift-artifacts.ts"

export type XcodePlatform = "macos" | "ios" | "pixelbook"

export interface XcodebuildOptions {
  readonly layout?: DevelopmentLayout
  readonly environment?: NodeJS.ProcessEnv
  readonly stdio?: StdioOptions
}

type Environment = Readonly<Record<string, string | undefined>>

const platforms: ReadonlySet<string> = new Set(["macos", "ios", "pixelbook"])
const standaloneOperations = new Set([
  "-exportArchive",
  "-downloadPlatform",
  "-list",
  "-showsdks",
  "-version"
])
const nonBuildingOperations = new Set([
  "-exportArchive",
  "-downloadPlatform",
  "-list",
  "-showBuildSettings",
  "-showdestinations",
  "-showsdks",
  "-version"
])

export function xcodebuildArguments(
  layout: DevelopmentLayout,
  platform: string,
  args: ReadonlyArray<string>
): Array<string> {
  if (!isPlatform(platform)) throw new Error(`Unknown Xcode platform ${platform}`)
  if (args.some((argument) => standaloneOperations.has(argument))) return [...args]

  const platformLayout = layout.build[platform]
  return [
    "-derivedDataPath",
    platformLayout.derivedData,
    "-clonedSourcePackagesDirPath",
    platformLayout.sourcePackages,
    "-packageCachePath",
    layout.build.packageCache,
    "-skipMacroValidation",
    "COMPILER_INDEX_STORE_ENABLE=NO",
    ...args
  ]
}

export function packageResolutionArguments(args: ReadonlyArray<string>): Array<string> | undefined {
  if (args.some((argument) => nonBuildingOperations.has(argument))) return undefined

  const selected: Array<string> = []
  for (const flag of ["-project", "-workspace", "-scheme"]) {
    const value = valueAfter(args, flag)
    if (value !== undefined) selected.push(flag, value)
  }
  return selected.includes("-project") || selected.includes("-workspace") ? selected : undefined
}

export function packageResolutionInputs(
  repoRoot: string,
  resolution: ReadonlyArray<string>
): Array<string> {
  const workspace = valueAfter(resolution, "-workspace")
  const pins =
    workspace === undefined
      ? join(resolvePath(repoRoot, valueAfter(resolution, "-project") ?? ""), "project.xcworkspace")
      : resolvePath(repoRoot, workspace)
  return [
    join(pins, "xcshareddata/swiftpm/Package.resolved"),
    join(repoRoot, "packages/swift/Package.swift"),
    join(repoRoot, "packages/swift/Package.resolved")
  ]
}

export async function runXcodebuild(
  repoRoot: string,
  platform: string,
  args: ReadonlyArray<string>,
  options: XcodebuildOptions = {}
): Promise<void> {
  const layout = options.layout ?? developmentLayout(repoRoot, options.environment)
  const xcodeArguments = xcodebuildArguments(layout, platform, args)
  if (!isPlatform(platform)) return

  const platformLayout = layout.build[platform]
  await Promise.all(
    [platformLayout.derivedData, platformLayout.sourcePackages, layout.build.packageCache].map(
      (directory) => mkdir(directory, { recursive: true })
    )
  )
  const resolution = packageResolutionArguments(args)
  if (resolution !== undefined) {
    await prepareSwiftArtifacts({
      stateDirectory: platformLayout.sourcePackages,
      store: layout.build.swiftArtifactStore,
      inputs: packageResolutionInputs(repoRoot, resolution),
      resolve: () =>
        spawnXcodebuild(
          repoRoot,
          xcodebuildArguments(layout, platform, [...resolution, "-resolvePackageDependencies"]),
          options
        )
    })
    if (args.includes("-resolvePackageDependencies")) return
  }
  await spawnXcodebuild(repoRoot, xcodeArguments, options)
}

async function spawnXcodebuild(
  repoRoot: string,
  xcodeArguments: ReadonlyArray<string>,
  options: XcodebuildOptions
): Promise<void> {
  console.log(`\n$ xcodebuild ${xcodeArguments.join(" ")}`)
  const environment = options.environment ?? process.env
  const formatted = options.stdio === undefined && formatsForGitHub(environment)
  const child = spawn("xcodebuild", xcodeArguments, {
    cwd: repoRoot,
    env: environment,
    stdio: formatted ? ["inherit", "pipe", "pipe"] : (options.stdio ?? "inherit")
  })
  const formatter = formatted ? pipeThroughXcbeautify(child, environment) : undefined
  const result = await waitForExit(child)
  if (formatter !== undefined) await waitForExit(formatter)
  if (result.code !== 0) throw new Error(`xcodebuild failed (${describeExit(result)})`)
}

function formatsForGitHub(environment: Environment): boolean {
  return (
    environment.GITHUB_ACTIONS === "true" &&
    environment.CODEVISOR_XCBEAUTIFY !== "0" &&
    hasXcbeautify(environment)
  )
}

function hasXcbeautify(environment: Environment): boolean {
  return spawnSync("xcbeautify", ["--version"], { env: environment, stdio: "ignore" }).status === 0
}

function pipeThroughXcbeautify(child: ChildProcess, environment: Environment): ChildProcess {
  const formatter = spawn("xcbeautify", ["--renderer", "github-actions"], {
    env: environment,
    stdio: ["pipe", "inherit", "inherit"]
  })
  child.stdout?.pipe(formatter.stdin, { end: false })
  child.stderr?.pipe(formatter.stdin, { end: false })
  child.once("close", () => formatter.stdin.end())
  return formatter
}

function valueAfter(args: ReadonlyArray<string>, flag: string): string | undefined {
  const index = args.indexOf(flag)
  return index === -1 ? undefined : args[index + 1]
}

function isPlatform(platform: string): platform is XcodePlatform {
  return platforms.has(platform)
}
