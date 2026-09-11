import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdir, mkdtemp, rm, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { chromiumHelperSuffixes } from "../chromium-artifact.mjs"
import {
  embeddedLibraries,
  signEmbeddedLibraries,
  verifyBrowserDistribution,
  verifyBrowserLinkage
} from "./macos-browser-artifact.mjs"

const storage = "CodevisorBrowserStorage.dylib"
const loadPath = `@rpath/${storage}`
const arches = ["arm64", "x86_64"]

async function fixture(t) {
  const root = await mkdtemp(join(tmpdir(), "codevisor-browser-artifact-"))
  t.after(() => rm(root, { recursive: true, force: true }))
  const app = join(root, "Codevisor.app")
  const frameworks = join(app, "Contents/Frameworks")
  await mkdir(frameworks, { recursive: true })
  await writeFile(join(frameworks, storage), "fixture")
  return { root, app, frameworks }
}

function inspection({ omitLink, missingArch, noTimestamp, invalidCertificate } = {}) {
  const calls = []
  const run = (command, args) => {
    calls.push({ command, args })
    const path = args.at(-1)
    if (command === "lipo") return path === missingArch ? "arm64" : arches.join(" ")
    if (command === "xcrun") return path === omitLink ? "" : `    ${loadPath}\n`
    if (args.includes("--verify")) {
      if (path === invalidCertificate) throw new Error("Certificate requirement failed")
      return ""
    }
    const arch = args[args.indexOf("--arch") + 1]
    return `TeamIdentifier=TESTTEAM01\nCodeDirectory flags=0x10000(runtime)\n${path.endsWith(storage) && arch === noTimestamp ? "Signed Time=local time" : "Timestamp=fixture timestamp"}\n`
  }
  return { calls, run }
}

test("release signing includes top-level libraries without touching sealed frameworks or aliases", async (t) => {
  const { app, frameworks } = await fixture(t)
  const futureLibrary = join(frameworks, "Another Library.dylib")
  const sealed = join(frameworks, "AlreadySigned.framework")
  await writeFile(futureLibrary, "fixture")
  await mkdir(sealed)
  await writeFile(join(sealed, "nested.dylib"), "fixture")
  await symlink(join(frameworks, storage), join(frameworks, "alias.dylib"))
  const expected = [futureLibrary, join(frameworks, storage)]
  assert.deepEqual(await embeddedLibraries(app), expected)
  const calls = []
  await signEmbeddedLibraries(app, "Developer ID Application: Fixture", (command, args) => {
    calls.push({ command, args })
  })
  assert.deepEqual(
    calls.map((call) => call.args.at(-1)),
    expected
  )
  for (const { command, args } of calls) {
    assert.equal(command, "codesign")
    assert.ok(args.includes("--timestamp"))
    assert.equal(args[args.indexOf("--options") + 1], "runtime")
    assert.equal(args[args.indexOf("--sign") + 1], "Developer ID Application: Fixture")
  }
})

test("ad-hoc packaging stays explicit and does not request a timestamp", async (t) => {
  const { app } = await fixture(t)
  await assert.rejects(signEmbeddedLibraries(app, ""), /explicit signing identity/)
  const calls = []
  await signEmbeddedLibraries(app, "-", (_, args) => calls.push(args))
  assert.equal(calls.length, 1)
  assert.ok(calls[0].includes("--timestamp=none"))
  assert.equal(calls[0][calls[0].indexOf("--sign") + 1], "-")
})

test("release verification catches the missing main dependency and missing helper architecture", async (t) => {
  const { app, frameworks } = await fixture(t)
  assert.throws(() => verifyBrowserLinkage(app, [], inspection().run), /architectures/)
  assert.throws(
    () =>
      verifyBrowserLinkage(
        app,
        arches,
        inspection({ omitLink: join(app, "Contents/MacOS/Codevisor") }).run
      ),
    /must load.*at startup/
  )
  const name = "Codevisor Browser Helper (Renderer)"
  assert.throws(
    () =>
      verifyBrowserLinkage(
        app,
        arches,
        inspection({ missingArch: join(frameworks, `${name}.app/Contents/MacOS`, name) }).run
      ),
    /missing x86_64/
  )
})

test("split app verification checks signatures and timestamps on every remaining library slice", async (t) => {
  const { app, frameworks } = await fixture(t)
  const inspected = inspection()
  await verifyBrowserDistribution(app, ["arm64"], inspected.run)
  const signatureChecks = inspected.calls.filter((call) => call.args.includes("--verify"))
  assert.equal(signatureChecks.length, chromiumHelperSuffixes.length + 2)
  for (const { args } of signatureChecks) {
    assert.ok(args.includes("--all-architectures"))
    const requirement = args[args.indexOf("-R") + 1]
    assert.match(requirement, /anchor apple generic/)
    assert.match(requirement, /1\.2\.840\.113635\.100\.6\.1\.13/)
    assert.match(requirement, /TESTTEAM01/)
  }
  await assert.rejects(
    verifyBrowserDistribution(app, ["arm64"], inspection({ noTimestamp: "x86_64" }).run),
    /x86_64.*secure timestamp/
  )
  await assert.rejects(
    verifyBrowserDistribution(
      app,
      arches,
      inspection({ invalidCertificate: join(frameworks, storage) }).run
    ),
    /Certificate requirement failed/
  )
})

test(
  "real universal Mach-O fixtures catch missing startup linkage and ad-hoc distribution signatures",
  { skip: process.platform !== "darwin" },
  async (t) => {
    const { root, app, frameworks } = await fixture(t)
    const mainSource = join(root, "main.c")
    const librarySource = join(root, "library.c")
    await writeFile(mainSource, "int main(void) { return 0; }\n")
    await writeFile(librarySource, "int fixture(void) { return 1; }\n")
    const library = join(frameworks, storage)
    const compile = (...args) =>
      execFileSync("xcrun", ["clang", "-arch", "arm64", "-arch", "x86_64", ...args], {
        stdio: "pipe"
      })
    compile("-dynamiclib", librarySource, "-Wl,-install_name," + loadPath, "-o", library)
    const binaries = [join(app, "Contents/MacOS/Codevisor")]
    for (const suffix of chromiumHelperSuffixes) {
      const name = `Codevisor Browser Helper${suffix}`
      binaries.push(join(frameworks, `${name}.app/Contents/MacOS`, name))
    }
    for (const binary of binaries) {
      await mkdir(join(binary, ".."), { recursive: true })
      compile(mainSource, "-Wl,-needed_library," + library, "-o", binary)
    }
    await signEmbeddedLibraries(app, "-")
    for (const binary of [...binaries].reverse()) {
      execFileSync("codesign", ["--force", "--sign", "-", "--options", "runtime", binary], {
        stdio: "pipe"
      })
    }
    verifyBrowserLinkage(app, arches)
    await assert.rejects(verifyBrowserDistribution(app, arches), /signing Team ID/)
    // Supply a claimed team so the real codesign requirement parser and trust
    // check run against the ad-hoc fixture. A malformed -R argument must not
    // masquerade as the intended rejection of a non-Developer-ID signature.
    await assert.rejects(
      verifyBrowserDistribution(app, arches, (command, args) => {
        if (command === "codesign" && args.includes("-d") && !args.includes("--arch")) {
          return "TeamIdentifier=TESTTEAM01\n"
        }
        return execFileSync(command, args, { encoding: "utf8", stdio: "pipe" })
      }),
      /code failed to satisfy specified code requirement/
    )
    compile(mainSource, "-o", binaries[0])
    assert.throws(() => verifyBrowserLinkage(app, arches), /must load.*at startup/)
  }
)
