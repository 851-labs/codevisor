import { makeSkillsInstallContext, type SkillsOperationsDeps } from "./skills-install-context.js"
import { makeSkillsCreateOperations } from "./skills-install-create.js"
import { makeSkillsHarnessOperations } from "./skills-install-harness.js"
import { makeSkillsRemoteOperations } from "./skills-install-remote.js"
import { makeSkillsSyncOperations } from "./skills-install-sync.js"

export type { SkillsOperationsDeps } from "./skills-install-context.js"

/// Every mutating skills operation, sharing one install context so the
/// create/import/promote paths all link skills into harnesses the same way.
export const makeSkillsOperations = (deps: SkillsOperationsDeps) => {
  const context = makeSkillsInstallContext(deps)
  return {
    ...makeSkillsCreateOperations(context),
    ...makeSkillsRemoteOperations(context),
    ...makeSkillsHarnessOperations(context),
    ...makeSkillsSyncOperations(context)
  }
}
