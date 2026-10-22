import assert from "node:assert/strict"
import { spawnSync } from "node:child_process"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { dirname, join } from "node:path"
import test from "node:test"

import { loadExemptions, repoRoot } from "./exemptions.mjs"

const styleRules = new Set([
  "eslint(no-nested-ternary)",
  "codevisor(no-effect-ternary)",
  "codevisor(named-sql)"
])

const repoConfig = () => {
  const config = JSON.parse(readFileSync(join(repoRoot, ".oxlintrc.json"), "utf8"))
  return { ...config, jsPlugins: config.jsPlugins.map((plugin) => join(repoRoot, plugin)) }
}

function lintWithRepoConfig(t, files) {
  const root = mkdtempSync(join(tmpdir(), "codevisor-lint-"))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  writeFileSync(join(root, ".oxlintrc.json"), JSON.stringify(repoConfig()))
  for (const [path, code] of Object.entries(files)) {
    mkdirSync(dirname(join(root, path)), { recursive: true })
    writeFileSync(join(root, path), code)
  }
  const { stdout } = spawnSync(
    join(repoRoot, "node_modules/.bin/oxlint"),
    ["-c", ".oxlintrc.json", "--disable-nested-config", "-f", "json", "."],
    { cwd: root, encoding: "utf8" }
  )
  return JSON.parse(stdout)
    .diagnostics.filter((diagnostic) => styleRules.has(diagnostic.code))
    .map((diagnostic) => `${diagnostic.filename} ${diagnostic.code}`)
    .toSorted()
}

const inlineSql = 'export const rows = (db) => db.prepare("select id from sessions").all()\n'

test("the repo config rejects nested, effect-choosing and SQL-running ternaries", (t) => {
  const violations = lintWithRepoConfig(t, {
    "packages/example/src/bad.ts": [
      'export const label = (n: number) => (n === 0 ? "none" : n === 1 ? "one" : "many")',
      "export const load = async (ready: boolean) => (ready ? await fetch('/') : undefined)",
      'export const stop = (ready: boolean) => { ready ? console.log("a") : console.log("b") }',
      inlineSql
    ].join("\n"),
    "packages/example/src/good.ts": [
      "const sessionIdsSql = 'select id from sessions'",
      "export const label = (n: number) => {",
      '  if (n === 0) return "none"',
      '  return n === 1 ? "one" : "many"',
      "}",
      "export const load = async (ready: boolean) => {",
      "  if (!ready) return undefined",
      "  return await fetch('/')",
      "}",
      "export const rows = (db) => db.prepare(sessionIdsSql).all()",
      ""
    ].join("\n")
  })
  assert.deepEqual(violations, [
    "packages/example/src/bad.ts codevisor(named-sql)",
    "packages/example/src/bad.ts codevisor(no-effect-ternary)",
    "packages/example/src/bad.ts codevisor(no-effect-ternary)",
    "packages/example/src/bad.ts eslint(no-nested-ternary)"
  ])
})

test("migrations, upgrades and tests may inline SQL", (t) => {
  const violations = lintWithRepoConfig(t, {
    "packages/db/src/migrations-99.ts": inlineSql,
    "packages/db/src/transcript-example-upgrade.ts": inlineSql,
    "packages/example/src/rows.test.ts": inlineSql,
    "packages/example/src/test-support.ts": inlineSql,
    "apps/example/test/rows.ts": inlineSql,
    "packages/example/src/rows.ts": inlineSql
  })
  assert.deepEqual(violations, ["packages/example/src/rows.ts codevisor(named-sql)"])
})

test("every lint exemption names a file that exists and gives a reason", () => {
  for (const [rule, entries] of Object.entries(loadExemptions())) {
    for (const { file, code, reason } of entries) {
      assert.ok(existsSync(join(repoRoot, file)), `${rule}: ${file} no longer exists`)
      assert.ok(code.length > 0 && reason.length > 0, `${rule}: ${file} needs code and a reason`)
    }
  }
})
