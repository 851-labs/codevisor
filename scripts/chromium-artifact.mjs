import { spawn } from "node:child_process"
import { createHash } from "node:crypto"
import { createReadStream } from "node:fs"
import { access, mkdir, readFile, rename, rm, symlink, writeFile } from "node:fs/promises"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

export const chromiumVersion = "152.0.5+gb129680+chromium-152.0.7977.54"
export const chromiumHelperName = (productName) =>
  productName.replace(/^Codevisor/, "Codevisor Browser Helper")
export const chromiumHelperSuffixes = ["", " (Alerts)", " (GPU)", " (Plugin)", " (Renderer)"]
const artifacts = {
  arm64: { platform: "macosarm64", sha1: "38b1b9d7f68c4e9c7dbd253b8f4129bea50a8c33" },
  x86_64: { platform: "macosx64", sha1: "52098375a0b18afeafcbbcb7d0be0f0a588afee1" }
}
export async function run(command, args, cwd, env = process.env) {
  const child = spawn(command, args, { cwd, env, stdio: "inherit" })
  await new Promise((resolve, reject) => {
    child.once("error", reject)
    child.once("exit", (code, signal) =>
      code === 0 ? resolve() : reject(new Error(`${command} failed: ${signal ?? code}`))
    )
  })
}
async function exists(path) {
  try {
    await access(path)
    return true
  } catch {
    return false
  }
}
async function digest(path, algorithm = "sha256") {
  const hash = createHash(algorithm)
  for await (const chunk of createReadStream(path)) hash.update(chunk)
  return hash.digest("hex")
}
export async function ensureChromium(
  repoRoot,
  environment = process.env,
  architectures = [process.arch === "arm64" ? "arm64" : "x86_64"]
) {
  const cache = join(repoRoot, "tmp/build/chromium")
  const output = join(repoRoot, "apps/macos/Frameworks/Chromium")
  await mkdir(cache, { recursive: true })
  await mkdir(output, { recursive: true })
  const cmake = join(cache, "build-tools/bin/cmake")
  if (!(await exists(cmake))) {
    await run("python3", ["-m", "venv", join(cache, "build-tools")], repoRoot, environment)
    await run(
      join(cache, "build-tools/bin/pip"),
      ["install", "cmake==4.1.3"],
      repoRoot,
      environment
    )
  }
  for (const arch of [...new Set(architectures)]) {
    const artifact = artifacts[arch]
    if (!artifact) throw new Error(`Unsupported Chromium architecture: ${arch}`)
    const name = `cef_binary_${chromiumVersion}_${artifact.platform}`
    const sdk = join(cache, name)
    if (!(await exists(join(sdk, "include/cef_version.h")))) {
      const archive = join(cache, `${name}.tar.bz2`)
      if (!(await exists(archive)) || (await digest(archive, "sha1")) !== artifact.sha1) {
        const temporary = archive + ".partial"
        await run(
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
        if ((await digest(temporary, "sha1")) !== artifact.sha1)
          throw new Error("CEF archive checksum mismatch")
        await rename(temporary, archive)
      }
      await run("tar", ["-xjf", archive, "-C", cache], repoRoot, environment)
    }
    const build = join(cache, `wrapper-${chromiumVersion}-${arch}`)
    const wrapper = join(build, "libcef_dll_wrapper/libcef_dll_wrapper.a")
    if (!(await exists(wrapper))) {
      await run(
        cmake,
        ["-S", sdk, "-B", build, `-DPROJECT_ARCH=${arch}`, "-DCMAKE_BUILD_TYPE=Release"],
        repoRoot,
        environment
      )
      await run(
        cmake,
        ["--build", build, "--target", "libcef_dll_wrapper", "-j", "8"],
        repoRoot,
        environment
      )
    }
    const destination = join(output, arch)
    await mkdir(destination, { recursive: true })
    for (const [source, name] of [
      [sdk, "sdk"],
      [wrapper, "libcef_dll_wrapper.a"]
    ]) {
      await rm(join(destination, name), { force: true })
      await symlink(source, join(destination, name))
    }
    const helper = join(destination, "Codevisor Helper")
    const helperSource = join(repoRoot, "apps/macos/ChromiumHelper/main.cc")
    const keychainSource = join(repoRoot, "apps/macos/ChromiumHelper/ChromiumKeychain.mm")
    const storageLibrary = join(destination, "CodevisorBrowserStorage.dylib")
    await run(
      "xcrun",
      [
        "clang++",
        "-std=c++20",
        "-arch",
        arch,
        "-mmacosx-version-min=12.0",
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
    const signature =
      "storage-library-v1" +
      chromiumVersion +
      arch +
      (await digest(helperSource)) +
      (await digest(keychainSource))
    const stamp = join(destination, "helper.stamp")
    if (
      !(await exists(helper)) ||
      !(await exists(stamp)) ||
      (await readFile(stamp, "utf8")) !== signature
    ) {
      await run(
        "xcrun",
        [
          "clang++",
          "-std=c++20",
          "-arch",
          arch,
          "-mmacosx-version-min=12.0",
          "-I",
          sdk,
          helperSource,
          `-Wl,-needed_library,${storageLibrary}`,
          "-Wl,-rpath,@loader_path/../../..",
          wrapper,
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
  }
}
if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  await ensureChromium(
    resolve(fileURLToPath(new URL("..", import.meta.url))),
    process.env,
    process.argv.slice(2).length ? process.argv.slice(2) : undefined
  )
}
