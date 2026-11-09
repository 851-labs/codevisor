import { chmod, mkdir, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it, vi } from "vitest"

import { developmentLayout } from "./dev-layout.ts"
import { runXcodebuild } from "./xcodebuild.ts"

const cleanups: Array<() => Promise<unknown>> = []
afterEach(async () => {
  vi.restoreAllMocks()
  await Promise.all(cleanups.splice(0).map((cleanup) => cleanup()))
})

const tool = (log: string, body: string) => `#!${process.execPath}
const fs = require("node:fs")
fs.appendFileSync(${JSON.stringify(log)}, JSON.stringify(process.argv.slice(2)) + "\\n")
${body}
`

async function fixture(xcodebuildBody = "") {
  vi.spyOn(console, "log").mockImplementation(() => {})
  const root = await mkdtemp(join(tmpdir(), "codevisor-xcodebuild-"))
  cleanups.push(() => rm(root, { recursive: true, force: true }))
  const bin = join(root, "bin")
  const repoRoot = join(root, "repo")
  const calls = join(root, "xcodebuild.jsonl")
  const formatted = join(root, "xcbeautify.txt")
  await mkdir(bin)
  await mkdir(join(repoRoot, "apps/ios/Codevisor.xcodeproj"), { recursive: true })
  await writeFile(join(bin, "xcodebuild"), tool(calls, xcodebuildBody))
  await writeFile(
    join(bin, "xcbeautify"),
    tool(
      join(root, "xcbeautify.jsonl"),
      `let input = ""
process.stdin.on("data", (chunk) => (input += chunk))
process.stdin.on("end", () => fs.writeFileSync(${JSON.stringify(formatted)}, input))`
    )
  )
  await chmod(join(bin, "xcodebuild"), 0o755)
  await chmod(join(bin, "xcbeautify"), 0o755)
  const environment = {
    PATH: `${bin}:${process.env.PATH ?? ""}`,
    CODEVISOR_SWIFT_PACKAGE_CACHE: join(root, "package-cache"),
    CODEVISOR_SWIFT_ARTIFACT_STORE: join(root, "store")
  }
  vi.stubEnv("PATH", environment.PATH)
  return {
    repoRoot,
    environment,
    layout: developmentLayout(repoRoot, environment),
    calls: async () =>
      (await readFile(calls, "utf8").catch(() => ""))
        .split("\n")
        .filter(Boolean)
        .map((line): Array<string> => JSON.parse(line)),
    formatted: () => readFile(formatted, "utf8")
  }
}

const project = ["-project", "apps/ios/Codevisor.xcodeproj", "-scheme", "Codevisor"]

describe("runXcodebuild", () => {
  it("resolves packages once per pin set before building", async () => {
    const { repoRoot, environment, layout, calls } = await fixture()

    await runXcodebuild(repoRoot, "ios", [...project, "build"], {
      environment,
      layout,
      stdio: "ignore"
    })
    await runXcodebuild(repoRoot, "ios", [...project, "build"], {
      environment,
      layout,
      stdio: "ignore"
    })

    expect((await calls()).map((args) => args.at(-1))).toEqual([
      "-resolvePackageDependencies",
      "build",
      "build"
    ])
  })

  it("stops after resolution when only resolution was asked for", async () => {
    const { repoRoot, environment, layout, calls } = await fixture()

    await runXcodebuild(repoRoot, "ios", [...project, "-resolvePackageDependencies"], {
      environment,
      layout,
      stdio: "ignore"
    })

    expect(await calls()).toHaveLength(1)
  })

  it("runs non-building operations directly and reports failures", async () => {
    const { repoRoot, environment, layout, calls } = await fixture("process.exit(65)")

    await expect(
      runXcodebuild(repoRoot, "macos", ["-version"], { environment, layout, stdio: "ignore" })
    ).rejects.toThrow("xcodebuild failed (code 65)")
    expect(await calls()).toHaveLength(1)
  })

  it("formats GitHub Actions output through xcbeautify", async () => {
    const { repoRoot, environment, layout, formatted } = await fixture(
      `process.stdout.write("Compiling App.swift\\n"); process.stderr.write("warning: unused\\n")`
    )

    await runXcodebuild(repoRoot, "macos", ["-version"], {
      environment: { ...environment, GITHUB_ACTIONS: "true" },
      layout
    })

    expect((await formatted()).split("\n").toSorted()).toEqual([
      "",
      "Compiling App.swift",
      "warning: unused"
    ])
  })
})
