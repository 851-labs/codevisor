import assert from "node:assert/strict"
import test from "node:test"

import { planChecks, relativeImports } from "./check-plan.mjs"

const context = {
  workspaces: [
    { directory: "apps/server", name: "@codevisor/server" },
    { directory: "packages/db", name: "@codevisor/db" }
  ],
  scriptInputs: {
    "scripts/test-swift.mjs": ["scripts/test-swift.mjs", "scripts/swift-artifacts.mjs"],
    "scripts/release": ["scripts/chromium-artifact.mjs"]
  },
  swiftLinks: [{ link: "packages/swift/Transcript/Sources", target: "apps/macos/Transcript" }]
}

const planned = (files, options = {}) =>
  Object.fromEntries(
    planChecks({ files, context, ...options })
      .filter(({ run, step }) => run && step.always !== true)
      .map(({ step, args }) => [step.name, args])
  )

test("a change with no matching inputs runs only the always-on checks", () => {
  assert.deepEqual(planned(["docs/plans/example.md", ".github/workflows/build.yml"]), {})
  assert.deepEqual(
    planChecks({ files: [], context })
      .filter(({ run }) => run)
      .map(({ step }) => step.name),
    ["format:check", "lint", "comments:check", "ratchet:check", "boundaries", "dev:scripts:test"]
  )
})

test("JavaScript changes run turbo for the changed packages and their dependents", () => {
  assert.deepEqual(planned(["packages/db/src/db.ts", "apps/server/src/server.ts"]), {
    typecheck: ["--filter=...@codevisor/db", "--filter=...@codevisor/server"],
    "test:coverage": ["--filter=...@codevisor/db", "--filter=...@codevisor/server"]
  })
  assert.deepEqual(planned(["tsconfig.base.json"]), {
    typecheck: [],
    "test:coverage": [],
    "typecheck:configs": []
  })
})

test("Vitest config changes type-check every Vitest config", () => {
  assert.deepEqual(planned(["packages/db/vitest.config.ts"]), {
    typecheck: ["--filter=...@codevisor/db"],
    "test:coverage": ["--filter=...@codevisor/db"],
    "typecheck:configs": []
  })
  assert.deepEqual(planned(["tsconfig.configs.json"]), { "typecheck:configs": [] })
})

test("release tests follow the release scripts, the installer, and the modules they import", () => {
  for (const file of [
    "scripts/release/install.test.mjs",
    "apps/www/public/install.sh",
    "scripts/chromium-artifact.mjs"
  ]) {
    assert.deepEqual(planned([file]), { "release:scripts:test": [] }, file)
  }
  assert.deepEqual(planned(["scripts/dev.mjs"]), {})
})

test("Swift changes run the Swift style checks and tests, and never build iOS", () => {
  const swiftChecks = ["swift:format:check", "swift:lint", "swift:test"]
  const changes = {
    "packages/swift/UI/Button.swift": swiftChecks,
    "packages/swift/UI/Vendor/grammar.c": ["swift:test"],
    "packages/swift/README.md": ["swift:test"],
    "packages/swift/Package.resolved": ["swift:test"],
    "apps/ios/Codevisor/App.swift": ["swift:format:check", "swift:lint"],
    "scripts/xcodebuild.mjs": [],
    "apps/macos/Transcript/Row.swift": swiftChecks,
    "apps/macos/Settings/Pane.swift": ["swift:format:check", "swift:lint"],
    "scripts/swift-artifacts.mjs": ["swift:test"],
    "packages/net/src/lib.rs": ["swift:test"]
  }
  for (const [file, checks] of Object.entries(changes)) {
    assert.deepEqual(Object.keys(planned([file])), checks, file)
  }
})

test("tooling changes and --all run every check", () => {
  const everything = planChecks({ files: [], context }).map(({ step }) => step.name)
  for (const options of [
    { files: ["lefthook.yml"] },
    { files: ["scripts/check.mjs"] },
    { files: [], all: true }
  ]) {
    const plan = planChecks({ context, ...options })
    assert.deepEqual(
      plan.filter(({ run }) => run).map(({ step }) => step.name),
      everything
    )
    assert.deepEqual(plan.find(({ step }) => step.name === "typecheck").args, [])
  }
})

test("script inputs follow static and dynamic relative imports", () => {
  assert.deepEqual(
    relativeImports(`import { a } from "./a.mjs"
import "node:fs"
import b from "../b.mjs"
const c = await import("./c.mjs")
export { d } from './d.mjs'`),
    ["./a.mjs", "../b.mjs", "./c.mjs", "./d.mjs"]
  )
})
