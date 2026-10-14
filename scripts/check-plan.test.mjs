import assert from "node:assert/strict"
import test from "node:test"

import { planChecks, relativeImports, xcodeSwiftProducts } from "./check-plan.mjs"

// A packages/swift shaped like the real one: an app-facing UI module, a
// screen-sharing engine, and a core both depend on.
const swiftPackage = {
  products: [
    { name: "Core", targets: ["Core"] },
    { name: "UI", targets: ["UI"] },
    { name: "Sharing", targets: ["Sharing"] }
  ],
  targets: [
    { name: "Core", type: "regular", path: "Core/Sources/Core", dependencies: [] },
    { name: "UI", type: "regular", path: "UI", dependencies: [{ byName: ["Core", null] }] },
    // Nested inside UI's folder, but its own module that nothing links.
    { name: "Grammars", type: "regular", path: "UI/Vendor", dependencies: [] },
    {
      name: "Sharing",
      type: "regular",
      path: "Sharing/Sources/Sharing",
      dependencies: [{ target: ["Core", null] }, { product: ["WebRTC", "webrtc", null, null] }]
    },
    { name: "CoreTests", type: "test", path: "Core/Tests/CoreTests", dependencies: [] },
    // App sources the package tests through a symlink; no product links it.
    {
      name: "Transcript",
      type: "regular",
      path: "Transcript/Sources",
      dependencies: [{ byName: ["UI", null] }]
    }
  ]
}

const context = {
  workspaces: [
    { directory: "apps/server", name: "@codevisor/server" },
    { directory: "packages/db", name: "@codevisor/db" }
  ],
  scriptInputs: {
    "scripts/test-swift.mjs": ["scripts/test-swift.mjs", "scripts/swift-artifacts.mjs"],
    "scripts/build-native.mjs": ["scripts/build-native.mjs", "scripts/xcodebuild.mjs"],
    "scripts/release": ["scripts/chromium-artifact.mjs"]
  },
  swiftPackage,
  rigProducts: ["Sharing", "ExternalProduct"],
  iosProducts: ["UI", "Core"],
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
    ["format:check", "lint", "ratchet:check", "boundaries", "dev:scripts:test"]
  )
})

test("JavaScript changes run turbo for the changed packages and their dependents", () => {
  assert.deepEqual(planned(["packages/db/src/db.ts", "apps/server/src/server.ts"]), {
    typecheck: ["--filter=...@codevisor/db", "--filter=...@codevisor/server"],
    "test:coverage": ["--filter=...@codevisor/db", "--filter=...@codevisor/server"]
  })
  // Shared configuration reaches every package.
  assert.deepEqual(planned(["tsconfig.base.json"]), { typecheck: [], "test:coverage": [] })
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

test("a Swift module change runs only the builds that link it", () => {
  const swiftChecks = ["swift:format:check", "swift:lint", "swift:test"]
  const changes = {
    "packages/swift/UI/Button.swift": [...swiftChecks, "swift:build:ios"],
    "packages/swift/UI/Vendor/grammar.c": ["swift:test"],
    "packages/swift/Sharing/Sources/Sharing/Peer.swift": [
      ...swiftChecks,
      "swift:test (screen-sharing-rig)"
    ],
    "packages/swift/Core/Sources/Core/Model.swift": [
      ...swiftChecks,
      "swift:test (screen-sharing-rig)",
      "swift:build:ios"
    ],
    "packages/swift/Core/Tests/CoreTests/ModelTests.swift": swiftChecks,
    "packages/swift/README.md": ["swift:test"],
    "packages/swift/Package.resolved": [
      "swift:test",
      "swift:test (screen-sharing-rig)",
      "swift:build:ios"
    ]
  }
  for (const [file, checks] of Object.entries(changes)) {
    assert.deepEqual(Object.keys(planned([file])), checks, file)
  }
})

test("app sources and native inputs run the Swift builds that consume them", () => {
  const changes = {
    "apps/ios/Codevisor/App.swift": ["swift:format:check", "swift:lint", "swift:build:ios"],
    "scripts/xcodebuild.mjs": ["swift:build:ios"],
    // Linked into packages/swift, so its tests run there; no app links it.
    "apps/macos/Transcript/Row.swift": ["swift:format:check", "swift:lint", "swift:test"],
    "apps/macos/Settings/Pane.swift": ["swift:format:check", "swift:lint"],
    "apps/screen-sharing-rig/Package.resolved": ["swift:test (screen-sharing-rig)"],
    "scripts/swift-artifacts.mjs": ["swift:test", "swift:test (screen-sharing-rig)"],
    "packages/net/src/lib.rs": ["swift:test", "swift:test (screen-sharing-rig)", "swift:build:ios"]
  }
  for (const [file, checks] of Object.entries(changes)) {
    assert.deepEqual(Object.keys(planned([file])), checks, file)
  }
})

test("without the Swift manifest or a build's products, every packages/swift change counts", () => {
  const file = "packages/swift/Core/Tests/CoreTests/ModelTests.swift"
  for (const missing of [{ swiftPackage: undefined }, { rigProducts: undefined }]) {
    const checks = planChecks({ files: [file], context: { ...context, ...missing } })
    assert.ok(
      checks.some(({ step, run }) => step.name === "swift:test (screen-sharing-rig)" && run),
      JSON.stringify(Object.keys(missing))
    )
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
    // Unfiltered, so turbo covers every package.
    assert.deepEqual(plan.find(({ step }) => step.name === "typecheck").args, [])
  }
})

test("Xcode projects list only the packages/swift products they link", () => {
  const project = `
/* Begin XCSwiftPackageProductDependency section */
		01 /* UI */ = {
			isa = XCSwiftPackageProductDependency;
			package = 00 /* XCLocalSwiftPackageReference "../../packages/swift" */;
			productName = UI;
		};
		02 /* GhosttyTerminal */ = {
			isa = XCSwiftPackageProductDependency;
			package = 03 /* XCLocalSwiftPackageReference "../../packages/ghostty-terminal" */;
			productName = GhosttyTerminal;
		};
/* End XCSwiftPackageProductDependency section */`
  assert.deepEqual(xcodeSwiftProducts(project), ["UI"])
  // An unrecognized project makes every packages/swift change count.
  assert.equal(xcodeSwiftProducts("// no package section"), undefined)
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
