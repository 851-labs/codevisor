import { createHash } from "node:crypto"
import { createReadStream } from "node:fs"
import { mkdir, readFile, rename, rm, symlink, writeFile } from "node:fs/promises"
import { homedir } from "node:os"
import { join } from "node:path"

import { withArtifactLock } from "./artifact-lock.ts"
import { runCommand } from "./commands.ts"
import { pathExists } from "./files.ts"

type Environment = Readonly<Record<string, string | undefined>>

export const chromiumVersion = "152.0.5+gb129680+chromium-152.0.7977.54"
export const chromiumHelperSuffixes = ["", " (Alerts)", " (GPU)", " (Plugin)", " (Renderer)"]
const artifacts: Readonly<Record<string, { readonly platform: string; readonly sha1: string }>> = {
  arm64: { platform: "macosarm64", sha1: "38b1b9d7f68c4e9c7dbd253b8f4129bea50a8c33" }
}

export function chromiumHelperName(productName: string): string {
  return productName.replace(/^Codevisor/, "Codevisor Browser Helper")
}

export function chromiumArtifactsRoot(environment: Environment = process.env): string {
  return (
    environment.CODEVISOR_CHROMIUM_ARTIFACTS_ROOT ??
    join(homedir(), ".codevisor-development", "artifacts", "chromium")
  )
}

export async function runTool(
  command: string,
  args: ReadonlyArray<string>,
  cwd: string,
  environment: Environment = process.env
): Promise<void> {
  await runCommand(command, args, { cwd, env: environment })
}

export async function ensureChromium(
  repoRoot: string,
  environment: Environment = process.env,
  architectures: ReadonlyArray<string> = ["arm64"]
): Promise<void> {
  const cache = chromiumArtifactsRoot(environment)
  const output = join(repoRoot, "apps/macos/Frameworks/Chromium")
  const archs = [...new Set(architectures)]
  for (const arch of archs) {
    if (artifacts[arch] === undefined) throw new Error(`Unsupported Chromium architecture: ${arch}`)
  }
  await mkdir(output, { recursive: true })
  await withArtifactLock(join(cache, ".lock"), async () => {
    const cmake = await ensureCmake(cache, repoRoot, environment)
    for (const arch of archs) await ensureSdkAndWrapper(cache, cmake, arch, repoRoot, environment)
  })
  for (const arch of archs)
    await buildHelpers(repoRoot, join(output, arch), sharedPaths(cache, arch), arch, environment)
}

interface SharedPaths {
  readonly name: string
  readonly sdk: string
  readonly build: string
  readonly wrapper: string
}

function sharedPaths(cache: string, arch: string): SharedPaths {
  const name = `cef_binary_${chromiumVersion}_${artifactFor(arch).platform}`
  const build = join(cache, `wrapper-${chromiumVersion}-${arch}`)
  return {
    name,
    sdk: join(cache, name),
    build,
    wrapper: join(build, "libcef_dll_wrapper/libcef_dll_wrapper.a")
  }
}

async function ensureCmake(
  cache: string,
  repoRoot: string,
  environment: Environment
): Promise<string> {
  const cmake = join(cache, "build-tools/bin/cmake")
  if (!(await pathExists(cmake))) {
    await runTool("python3", ["-m", "venv", join(cache, "build-tools")], repoRoot, environment)
    await runTool(
      join(cache, "build-tools/bin/pip"),
      ["install", "cmake==4.1.3"],
      repoRoot,
      environment
    )
  }
  return cmake
}

async function ensureSdkAndWrapper(
  cache: string,
  cmake: string,
  arch: string,
  repoRoot: string,
  environment: Environment
): Promise<void> {
  const { name, sdk, build, wrapper } = sharedPaths(cache, arch)
  const { sha1 } = artifactFor(arch)
  if (!(await pathExists(join(sdk, "include/cef_version.h")))) {
    const archive = join(cache, `${name}.tar.bz2`)
    if (!(await pathExists(archive)) || (await digest(archive, "sha1")) !== sha1) {
      const temporary = `${archive}.partial`
      await runTool(
        "curl",
        [
          "--fail",
          "--location",
          "--retry",
          "3",
          "--output",
          temporary,
          `https://cef-builds.spotifycdn.com/${name}.tar.bz2`
        ],
        repoRoot,
        environment
      )
      if ((await digest(temporary, "sha1")) !== sha1)
        throw new Error("CEF archive checksum mismatch")
      await rename(temporary, archive)
    }
    await runTool("tar", ["-xjf", archive, "-C", cache], repoRoot, environment)
  }
  if (!(await pathExists(wrapper))) {
    await runTool(
      cmake,
      ["-S", sdk, "-B", build, `-DPROJECT_ARCH=${arch}`, "-DCMAKE_BUILD_TYPE=Release"],
      repoRoot,
      environment
    )
    await runTool(
      cmake,
      ["--build", build, "--target", "libcef_dll_wrapper", "-j", "8"],
      repoRoot,
      environment
    )
  }
}

async function buildHelpers(
  repoRoot: string,
  destination: string,
  shared: SharedPaths,
  arch: string,
  environment: Environment
): Promise<void> {
  await mkdir(destination, { recursive: true })
  for (const [source, name] of [
    [shared.sdk, "sdk"],
    [shared.wrapper, "libcef_dll_wrapper.a"]
  ] as const) {
    await rm(join(destination, name), { force: true })
    await symlink(source, join(destination, name))
  }

  const helper = join(destination, "Codevisor Helper")
  const helperSource = join(repoRoot, "apps/macos/ChromiumHelper/main.cc")
  const keychainSource = join(repoRoot, "apps/macos/ChromiumHelper/ChromiumKeychain.mm")
  const storageLibrary = join(destination, "CodevisorBrowserStorage.dylib")
  const compile = ["clang++", "-std=c++20", "-arch", arch, "-mmacosx-version-min=12.0"]
  await runTool(
    "xcrun",
    [
      ...compile,
      "-dynamiclib",
      "-fobjc-arc",
      keychainSource,
      "-framework",
      "Foundation",
      "-framework",
      "Security",
      "-install_name",
      "@rpath/CodevisorBrowserStorage.dylib",
      "-o",
      storageLibrary
    ],
    repoRoot,
    environment
  )

  const signature = `storage-library-v1${chromiumVersion}${arch}${await digest(helperSource)}${await digest(keychainSource)}`
  const stamp = join(destination, "helper.stamp")
  const current = await readFile(stamp, "utf8").catch(() => undefined)
  if ((await pathExists(helper)) && current === signature) return

  await runTool(
    "xcrun",
    [
      ...compile,
      "-I",
      shared.sdk,
      helperSource,
      `-Wl,-needed_library,${storageLibrary}`,
      "-Wl,-rpath,@loader_path/../../..",
      shared.wrapper,
      "-framework",
      "AppKit",
      "-framework",
      "Security",
      "-o",
      helper
    ],
    repoRoot,
    environment
  )
  await writeFile(stamp, signature)
}

function artifactFor(arch: string): { readonly platform: string; readonly sha1: string } {
  const artifact = artifacts[arch]
  if (artifact === undefined) throw new Error(`Unsupported Chromium architecture: ${arch}`)
  return artifact
}

async function digest(path: string, algorithm = "sha256"): Promise<string> {
  const hash = createHash(algorithm)
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return hash.digest("hex")
}
