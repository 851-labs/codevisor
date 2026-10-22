import { loadExemptions } from "./exemptions.mjs"
import { namedSql } from "./named-sql.mjs"
import { noComments } from "./no-comments.mjs"
import { noEffectTernary } from "./no-effect-ternary.mjs"

const exemptions = loadExemptions()

export default {
  meta: { name: "codevisor" },
  rules: {
    "no-comments": noComments,
    "no-effect-ternary": noEffectTernary(exemptions["codevisor/no-effect-ternary"]),
    "named-sql": namedSql(exemptions["codevisor/named-sql"])
  }
}
