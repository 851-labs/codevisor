import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

import { hostTarget } from "./net-artifact.ts"
import { buildNodeAddon, buildSwiftFramework } from "./net-build.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

describe("buildNodeAddon", () => {
  it("cross-builds Linux addons in a pinned Rust container and installs the result", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-net-build-"))
    cleanups.push(() => rm(root, { recursive: true, force: true }))
    const repoRoot = join(root, "repo")
    const bin = join(root, "bin")
    const calls = join(root, "docker.json")
    const target = hostTarget() === "linux-x64" ? "linux-arm64" : "linux-x64"
    await mkdir(join(repoRoot, "packages/net"), { recursive: true })
    await mkdir(bin)
    await writeFile(join(repoRoot, "rust-toolchain.toml"), 'channel = "1.98.1"\n')
    await writeFile(
      join(bin, "docker"),
      `#!${process.execPath}
const fs = require("node:fs")
const args = process.argv.slice(2)
fs.writeFileSync(${JSON.stringify(calls)}, JSON.stringify(args))
const source = args[args.indexOf("--volume") + 1].split(":")[0]
const library = source + args.at(-1).replace("/src", "") + "/release/libcodevisor_net_node.so"
fs.mkdirSync(require("node:path").dirname(library), { recursive: true })
fs.writeFileSync(library, "linux addon")
`
    )
    await chmod(join(bin, "docker"), 0o755)
    vi.stubEnv("PATH", `${bin}:${process.env.PATH ?? ""}`)

    await buildNodeAddon(repoRoot, target, {
      CODEVISOR_NET_ARTIFACTS_ROOT: join(root, "artifacts")
    })

    expect(
      await readFile(join(repoRoot, "packages/net/native", target, "codevisor_net.node"), "utf8")
    ).toBe("linux addon")
    const args: unknown = JSON.parse(await readFile(calls, "utf8"))
    expect(args).toContain("rust:1.98.1-bookworm")
    expect(args).toContain(`${join(root, "artifacts/linux-cargo-home")}:/cargo-home`)
  })

  it("builds the host addon and the Swift framework with the pinned toolchain", async () => {
    const root = await mkdtemp(join(tmpdir(), "codevisor-net-build-"))
    cleanups.push(() => rm(root, { recursive: true, force: true }))
    const repoRoot = join(root, "repo")
    const cargoBin = join(root, "home/.cargo/bin")
    const calls = join(root, "calls.txt")
    await mkdir(join(repoRoot, "packages/net"), { recursive: true })
    await mkdir(join(repoRoot, "scripts"), { recursive: true })
    await mkdir(cargoBin, { recursive: true })
    await writeFile(join(repoRoot, "rust-toolchain.toml"), 'channel = "1.98.1"\n')
    await writeFile(
      join(repoRoot, "scripts/net-build.lock.json"),
      JSON.stringify({
        linuxGlibc: "2.28",
        certbot: "5.8.0",
        relay: { version: "1.2.0", assets: {} }
      })
    )
    await writeFile(
      join(repoRoot, "scripts/build-net-swift.sh"),
      'mkdir -p "$1" && echo "$RUSTUP_TOOLCHAIN" > "$1/toolchain"\n'
    )
    await writeFile(join(cargoBin, "rustup"), `#!/bin/sh\necho "rustup $*" >> "${calls}"\n`)
    await writeFile(
      join(cargoBin, "cargo"),
      `#!${process.execPath}
const fs = require("node:fs")
const args = process.argv.slice(2)
fs.appendFileSync(${JSON.stringify(calls)}, "cargo " + args.join(" ") + "\\n")
const target = args.includes("--target") ? args[args.indexOf("--target") + 1].split(".")[0] + "/" : ""
const library = "target/" + target + "release/libcodevisor_net_node." + (process.platform === "linux" ? "so" : "dylib")
fs.mkdirSync(require("node:path").dirname(library), { recursive: true })
fs.writeFileSync(library, "host addon")
`
    )
    await chmod(join(cargoBin, "rustup"), 0o755)
    await chmod(join(cargoBin, "cargo"), 0o755)
    vi.stubEnv("HOME", join(root, "home"))

    await buildNodeAddon(repoRoot, hostTarget(), { PATH: process.env.PATH })
    await buildSwiftFramework(repoRoot, { PATH: process.env.PATH })

    expect(
      await readFile(
        join(repoRoot, "packages/net/native", hostTarget(), "codevisor_net.node"),
        "utf8"
      )
    ).toBe("host addon")
    expect(await readFile(join(repoRoot, "packages/net/native/apple/toolchain"), "utf8")).toBe(
      "1.98.1\n"
    )
    const log = await readFile(calls, "utf8")
    expect(log).toContain("rustup toolchain install 1.98.1 --profile minimal")
    expect(log).toMatch(
      process.platform === "linux"
        ? /cargo zigbuild .*--target \S+\.2\.28/
        : /cargo build --release --locked -p codevisor-net-node/
    )
  })

  it("refuses targets it can't build from this host", async () => {
    await expect(buildNodeAddon("/repo", "win32-x64")).rejects.toThrow(
      /can't build the codevisor-net addon for win32-x64/
    )
  })
})
