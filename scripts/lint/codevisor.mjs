import { loadExemptions } from "./exemptions.mjs"
import { isolatedModuleMocks } from "./isolated-module-mocks.mjs"
import { locatedGit } from "./located-git.mjs"
import { namedSql } from "./named-sql.mjs"
import { noComments } from "./no-comments.mjs"
import { noEffectTernary } from "./no-effect-ternary.mjs"
import { noImportTimeTestHooks } from "./no-import-time-test-hooks.mjs"

const exemptions = loadExemptions()

export default {
  meta: { name: "codevisor" },
  rules: {
    "no-comments": noComments,
    "no-effect-ternary": noEffectTernary(exemptions["codevisor/no-effect-ternary"]),
    "named-sql": namedSql(exemptions["codevisor/named-sql"]),
    "isolated-module-mocks": isolatedModuleMocks,
    "located-git": locatedGit,
    "no-import-time-test-hooks": noImportTimeTestHooks
  }
}
