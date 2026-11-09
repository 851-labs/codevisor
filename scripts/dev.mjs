import { fileURLToPath } from "node:url"

import { runOwnedTask } from "../packages/devtools/src/owned-task.ts"

await runOwnedTask(fileURLToPath(new URL("./dev-owner.mjs", import.meta.url)), [
  "all",
  ...process.argv.slice(2)
])
