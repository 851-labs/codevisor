import { fileURLToPath } from "node:url"

import { runOwnedTask } from "./owned-task.ts"

runOwnedTask(fileURLToPath(new URL("./dev-owner.ts", import.meta.url)), [
  "ios",
  ...process.argv.slice(2)
])
