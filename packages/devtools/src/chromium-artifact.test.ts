import { chmod, mkdir, mkdtemp, readFile, readlink, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import {
  chromiumArtifactsRoot,
  chromiumHelperName,
  chromiumVersion,
  ensureChromium
} from "./chromium-artifact.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

async function fixture() {
  const root = await mkdtemp(join(tmpdir(), "codevisor-chromium-test-"))
  cleanups.push(() => rm(root, { recursive: true, force: true }))
  const cache = join(root, "cache")
  const repoRoot = join(root, "repo")
  const bin = join(root, "bin")
  const calls = join(root, "xcrun.jsonl")
  const sdk = join(cache, `cef_binary_${chromiumVersion}_macosarm64`)
  const wrapper = join(
    cache,
    `wrapper-${chromiumVersion}-arm64/libcef_dll_wrapper/libcef_dll_wrapper.a`
  )
  for (const directory of [
    join(sdk, "include"),
    join(wrapper, ".."),
    join(cache, "build-tools/bin"),
    join(repoRoot, "apps/macos/ChromiumHelper"),
    bin
  ]) {
    await mkdir(directory, { recursive: true })
  }
  await writeFile(join(sdk, "include/cef_version.h"), "")
  await writeFile(wrapper, "")
  await writeFile(join(cache, "build-tools/bin/cmake"), "")
  await writeFile(join(repoRoot, "apps/macos/ChromiumHelper/main.cc"), "int main() {}")
  await writeFile(join(repoRoot, "apps/macos/ChromiumHelper/ChromiumKeychain.mm"), "")
  await writeFile(
    join(bin, "xcrun"),
    `#!${process.execPath}
const fs = require("node:fs")
const args = process.argv.slice(2)
fs.appendFileSync(${JSON.stringify(calls)}, JSON.stringify(args) + "\\n")
fs.writeFileSync(args[args.indexOf("-o") + 1], "built")
`
  )
  await chmod(join(bin, "xcrun"), 0o755)
  const environment = {
    CODEVISOR_CHROMIUM_ARTIFACTS_ROOT: cache,
    PATH: `${bin}:${process.env.PATH ?? ""}`
  }
  const outputs = async () =>
    (await readFile(calls, "utf8"))
      .trim()
      .split("\n")
      .map((line): Array<string> => JSON.parse(line))
      .map((args) => args[args.indexOf("-o") + 1])
  return {
    repoRoot,
    environment,
    sdk,
    outputs,
    output: join(repoRoot, "apps/macos/Frameworks/Chromium/arm64")
  }
}

describe("Chromium artifacts", () => {
  it("names helpers after the product and honors the shared artifacts root", () => {
    expect(chromiumHelperName("Codevisor (apricot)")).toBe("Codevisor Browser Helper (apricot)")
    expect(chromiumArtifactsRoot({ CODEVISOR_CHROMIUM_ARTIFACTS_ROOT: "/shared/chromium" })).toBe(
      "/shared/chromium"
    )
  })

  it("rejects architectures it has no CEF build for", async () => {
    await expect(ensureChromium("/repo", {}, ["x86_64"])).rejects.toThrow(
      "Unsupported Chromium architecture: x86_64"
    )
  })

  it("links the shared SDK and rebuilds the helper only when its sources change", async () => {
    const { repoRoot, environment, sdk, outputs, output } = await fixture()

    await ensureChromium(repoRoot, environment)
    await ensureChromium(repoRoot, environment)
    await writeFile(join(repoRoot, "apps/macos/ChromiumHelper/main.cc"), "int main() { return 1; }")
    await ensureChromium(repoRoot, environment, ["arm64", "arm64"])

    expect(await readlink(join(output, "sdk"))).toBe(sdk)
    const storage = join(output, "CodevisorBrowserStorage.dylib")
    const helper = join(output, "Codevisor Helper")
    expect(await outputs()).toEqual([storage, helper, storage, storage, helper])
  })
})
