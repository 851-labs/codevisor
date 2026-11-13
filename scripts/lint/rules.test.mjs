import { join } from "node:path"
import { describe, it } from "node:test"

import { RuleTester } from "oxlint/plugins-dev"

import { repoRoot } from "./exemptions.mjs"
import { isolatedModuleMocks } from "./isolated-module-mocks.mjs"
import { locatedGit } from "./located-git.mjs"
import { namedSql } from "./named-sql.mjs"
import { noEffectTernary } from "./no-effect-ternary.mjs"
import { noImportTimeTestHooks } from "./no-import-time-test-hooks.mjs"

RuleTester.describe = describe
RuleTester.it = it

const tester = new RuleTester({ languageOptions: { sourceType: "module" } })
const filename = join(repoRoot, "apps/server/src/example.ts")
const exempt = (code) => [{ file: "apps/server/src/example.ts", code, reason: "fixture" }]
const stale = { message: /^Stale exemption in scripts\/lint\/exemptions\.json/ }

describe("codevisor/no-effect-ternary", () => {
  const exempted = "const exempted = async () => (ready ? await load() : undefined)\n"
  const valid = (code) => ({ filename, code: exempted + code })
  const invalid = (code, message) => ({ filename, code: exempted + code, errors: [{ message }] })
  tester.run("no-effect-ternary", noEffectTernary(exempt("ready ? await load() : undefined")), {
    valid: [
      valid('const label = count === 1 ? "item" : "items"'),
      valid("const value = ready ? read() : fallback()"),
      valid("const value = (await ready()) ? 1 : 2"),
      valid("const load = ready ? async () => { await fetch(url) } : undefined"),
      valid("function* walk() { const next = ready ? function* () { yield 1 } : undefined }")
    ],
    invalid: [
      invalid(
        "async function load() { return other ? await fetch(url) : undefined }",
        /runs an await in a branch/
      ),
      invalid("function* walk() { const next = ready ? yield 1 : 2 }", /runs a yield in a branch/),
      invalid("const value = ready ? (cached = read()) : cached", /runs an assignment in a branch/),
      invalid("ready ? start() : stop()", /value is discarded/),
      invalid("void (ready ? start() : stop())", /value is discarded/),
      invalid("const value = (ready ? start() : stop(), done())", /value is discarded/),
      {
        filename,
        code: "const exempted = async () => (other ? await load() : undefined)",
        errors: [stale, { message: /runs an await in a branch/ }]
      }
    ]
  })
})

describe("codevisor/named-sql", () => {
  tester.run("named-sql", namedSql(exempt("`drop trigger ${name}`")), {
    valid: [
      { filename, code: "db.exec(`drop trigger ${name}`)" },
      { filename, code: "db.exec(`drop trigger ${name}`); db.prepare(selectSessionSql).get(id)" },
      {
        filename,
        code: "db.exec(`drop trigger ${name}`); db.prepare(sessionSql.deleteThrough).run(id)"
      },
      { filename, code: 'db.exec(`drop trigger ${name}`); task.run("selection")' }
    ],
    invalid: [
      {
        filename,
        code: 'db.exec(`drop trigger ${name}`); db.prepare("select * from sessions").all()',
        errors: [{ message: /^Name this query: .* to \.prepare\(\)\.$/ }]
      },
      {
        filename,
        code: "db.exec(`drop trigger ${name}`); db.exec(`CREATE TABLE t (id integer)`)",
        errors: [{ message: /to \.exec\(\)/ }]
      },
      {
        filename,
        code: 'db.exec(`drop trigger ${name}`); db.run("  insert into t values (?)", 1)',
        errors: [{ message: /to \.run\(\)/ }]
      },
      {
        filename,
        code: 'db.exec(`drop trigger ${name}`); db.prepare("select " + column + " from t")',
        errors: 1
      },
      {
        filename,
        code: "db.exec(`drop trigger ${other}`)",
        errors: [stale, { message: /to \.exec\(\)/ }]
      }
    ]
  })
})

describe("codevisor/isolated-module-mocks", () => {
  const shared = join(repoRoot, "apps/server/src/example.test.ts")
  const isolated = join(repoRoot, "apps/server/src/example.isolated.test.ts")
  const message = /Rename it to \*\.isolated\.test\.ts\.$/
  tester.run("isolated-module-mocks", isolatedModuleMocks, {
    valid: [
      { filename: isolated, code: 'vi.mock("node:fs"); vi.doMock("./a.js"); vi.resetModules()' },
      { filename: shared, code: 'vi.spyOn(console, "error"); vi.fn(); mock("node:fs")' }
    ],
    invalid: [
      { filename: shared, code: 'vi.mock("node:fs")', errors: [{ message: /^vi\.mock\(\)/ }] },
      { filename: shared, code: 'vi.doMock("./a.js")', errors: [{ message }] },
      { filename: shared, code: 'vi.unmock("./a.js")', errors: [{ message }] },
      { filename: shared, code: "vi.resetModules()", errors: [{ message }] }
    ]
  })
})

describe("codevisor/located-git", () => {
  const message = /^Run Git through gitExecutable\(\)/
  tester.run("located-git", locatedGit, {
    valid: [
      { filename, code: "spawn(await gitExecutable(), args)" },
      { filename, code: 'withPriority(executable, ["status"], priority)' },
      {
        filename,
        code: 'spawn("gh", ["auth", "status"]); field(payload, "git"); join(store, "git")'
      }
    ],
    invalid: [
      { filename, code: 'spawn("git", ["status"])', errors: [{ message }] },
      { filename, code: 'execFile("git", args, done)', errors: [{ message }] },
      { filename, code: 'await execFileAsync("git", ["config"])', errors: [{ message }] },
      { filename, code: 'childProcess.spawnSync("git", args)', errors: [{ message }] },
      { filename, code: 'withPriority("git", args, priority)', errors: [{ message }] }
    ]
  })
})

describe("codevisor/no-import-time-test-hooks", () => {
  const support = join(repoRoot, "apps/server/src/example-test-support.ts")
  const message = /runs only for the first test file that imports it/
  tester.run("no-import-time-test-hooks", noImportTimeTestHooks, {
    valid: [
      { filename: join(repoRoot, "apps/server/src/example.test.ts"), code: "afterEach(cleanup)" },
      { filename: join(repoRoot, "apps/server/src/test-setup.ts"), code: "beforeEach(stub)" },
      { filename: support, code: "export const temp = () => onTestFinished(cleanup)" },
      { filename: support, code: "export const fixture = () => { beforeEach(stub) }" }
    ],
    invalid: [
      { filename: support, code: "beforeEach(stub)", errors: [{ message: /^beforeEach\(\)/ }] },
      {
        filename: support,
        code: "afterEach(cleanup)\nbeforeAll(start)\nafterAll(stop)",
        errors: [{ message }, { message }, { message }]
      }
    ]
  })
})
