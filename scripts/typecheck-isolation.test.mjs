import assert from "node:assert/strict"
import { execFileSync } from "node:child_process"
import { mkdirSync, mkdtempSync, readFileSync, readdirSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import test from "node:test"
import { fileURLToPath } from "node:url"

const root = dirname(dirname(fileURLToPath(import.meta.url)))
const tsc = join(root, "node_modules/typescript/bin/tsc")
const commands = new Set()
for (const category of ["packages", "apps"]) {
  for (const entry of readdirSync(join(root, category), { withFileTypes: true })) {
    if (!entry.isDirectory()) continue
    let manifest
    try {
      manifest = JSON.parse(readFileSync(join(root, category, entry.name, "package.json"), "utf8"))
    } catch (error) {
      if (error.code === "ENOENT") continue
      throw error
    }
    if (manifest.scripts?.build === "tsc -b tsconfig.json") {
      commands.add(manifest.scripts.typecheck.split(" && ")[0])
    }
  }
}

// Run each distinct workspace typecheck command against a real composite project.
// Cold checks must not publish JS; warm checks must not poison the build's cache.
for (const command of commands) {
  test(`typecheck leaves runtime output and build metadata alone: ${command}`, (t) => {
    const directory = mkdtempSync(join(tmpdir(), "codevisor-typecheck-"))
    t.after(() => rmSync(directory, { recursive: true, force: true }))
    mkdirSync(join(directory, "src"))
    writeFileSync(join(directory, "package.json"), JSON.stringify({ type: "module" }))
    writeFileSync(
      join(directory, "tsconfig.json"),
      JSON.stringify({
        compilerOptions: {
          composite: true,
          module: "NodeNext",
          target: "ES2024",
          rootDir: "src",
          outDir: "dist",
          types: []
        },
        include: ["src/**/*.ts"]
      })
    )
    const source = join(directory, "src/index.ts")
    writeFileSync(source, 'export const treeHash = (): string => "before"\n')
    const [executable, ...args] = command.split(" ")
    assert.equal(executable, "tsc")
    const run = (args) => execFileSync(process.execPath, [tsc, ...args], { cwd: directory })

    run(args)
    assert.throws(() => readdirSync(join(directory, "dist")), { code: "ENOENT" })
    assert.throws(() => readFileSync(join(directory, "tsconfig.tsbuildinfo")), { code: "ENOENT" })

    run(["-b", "tsconfig.json"])
    const paths = ["dist/index.js", "dist/index.d.ts", "tsconfig.tsbuildinfo"]
    const before = paths.map((path) => readFileSync(join(directory, path), "utf8"))
    writeFileSync(source, 'export const treeHash = (): string => "after"\n')
    run(args)
    assert.deepEqual(
      paths.map((path) => readFileSync(join(directory, path), "utf8")),
      before
    )

    // The next build must still see the source change and publish its new value.
    run(["-b", "tsconfig.json"])
    assert.match(readFileSync(join(directory, "dist/index.js"), "utf8"), /"after"/)

    writeFileSync(source, "export const treeHash = (): string => 42\n")
    assert.throws(
      () => run(args),
      (error) => {
        assert.notEqual(error.status, 0)
        assert.match(error.stdout.toString(), /TS2322/)
        return true
      }
    )
  })
}
