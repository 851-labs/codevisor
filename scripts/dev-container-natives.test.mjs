import assert from "node:assert/strict"
import { mkdir, mkdtemp, rm, stat, symlink, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

import { verifyTrustedDependencies, workspaceDirectories } from "./dev-container-natives.mjs"

const writeJson = (path, value) => writeFile(path, JSON.stringify(value))

/// A bun isolated-linker layout: the package lives in the node_modules/.bun
/// store, only the declaring workspace links it, and the root never does.
/// Each fixture is a unique directory, so Node's require cache cannot leak
/// one test's module into another.
const isolatedFixture = async (
  t,
  {
    moduleSource = "module.exports = { loaded: true }",
    linked = true,
    trusted = ["fake-native"]
  } = {}
) => {
  const root = await mkdtemp(join(tmpdir(), "dev-container-natives-"))
  t.after(() => rm(root, { recursive: true, force: true }))
  await writeJson(join(root, "package.json"), {
    workspaces: ["packages/*", "apps/*"],
    trustedDependencies: trusted
  })
  const store = join(
    root,
    "node_modules",
    ".bun",
    "fake-native@1.0.0",
    "node_modules",
    "fake-native"
  )
  await mkdir(store, { recursive: true })
  await writeJson(join(store, "package.json"), {
    name: "fake-native",
    version: "1.0.0",
    main: "index.js"
  })
  await writeFile(join(store, "index.js"), moduleSource)

  const terminal = join(root, "packages", "terminal")
  await mkdir(join(terminal, "node_modules"), { recursive: true })
  await writeJson(join(terminal, "package.json"), {
    name: "@fixture/terminal",
    dependencies: { "fake-native": "1.0.0" }
  })
  if (linked) await symlink(store, join(terminal, "node_modules", "fake-native"))

  // A workspace that does not declare the dependency must not be checked.
  const www = join(root, "apps", "www")
  await mkdir(www, { recursive: true })
  await writeJson(join(www, "package.json"), { name: "@fixture/www", dependencies: {} })
  return root
}

test("loads trusted dependencies from the workspace that declares them, never the root", async (t) => {
  const root = await isolatedFixture(t)
  await assert.rejects(
    stat(join(root, "node_modules", "fake-native")),
    "fixture must not hoist to root"
  )

  const result = await verifyTrustedDependencies(root)

  assert.deepEqual(result.checks, [
    { name: "fake-native", workspace: join("packages", "terminal") }
  ])
  assert.deepEqual(result.failures, [])
  assert.deepEqual(result.undeclared, [])
})

test("reports a workspace whose link to the trusted dependency is missing", async (t) => {
  const root = await isolatedFixture(t, { linked: false })

  const result = await verifyTrustedDependencies(root)

  assert.equal(result.failures.length, 1)
  assert.equal(result.failures[0].workspace, join("packages", "terminal"))
  assert.match(result.failures[0].error, /Cannot find module 'fake-native'/)
})

test("reports an addon whose binding fails to load", async (t) => {
  const root = await isolatedFixture(t, {
    moduleSource:
      'throw new Error("Could not locate the bindings file. Tried: build/Release/pty.node")'
  })

  const result = await verifyTrustedDependencies(root)

  assert.equal(result.failures.length, 1)
  assert.match(result.failures[0].error, /pty\.node/)
})

test("reports trusted dependencies that no workspace declares without failing", async (t) => {
  const root = await isolatedFixture(t, { trusted: ["fake-native", "orphan-native"] })

  const result = await verifyTrustedDependencies(root)

  assert.deepEqual(result.undeclared, ["orphan-native"])
  assert.deepEqual(result.failures, [])
})

test("workspaceDirectories lists only packages with a manifest and rejects unsupported globs", async (t) => {
  const root = await isolatedFixture(t)
  await mkdir(join(root, "packages", "no-manifest"), { recursive: true })

  const directories = await workspaceDirectories(root, ["packages/*", "apps/*", "missing/*"])

  assert.deepEqual(directories, [join(root, "packages", "terminal"), join(root, "apps", "www")])
  await assert.rejects(workspaceDirectories(root, ["packages/**"]), /unsupported workspace pattern/)
})
