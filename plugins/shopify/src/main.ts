import { serveStdio } from "@codevisor/plugin-kit"

import { makeCliLocator, defaultToolsDir } from "./shopify-cli-install.js"
import { makeShopifyCli } from "./shopify-cli.js"
import { runProcess } from "./shopify-process.js"
import { createShopifyServer } from "./shopify-server.js"

const locate = makeCliLocator({
  env: process.env,
  toolsDir: defaultToolsDir(process.env),
  nodePath: process.execPath,
  run: runProcess
})

await serveStdio(
  createShopifyServer(makeShopifyCli({ locate, run: runProcess })),
  process.stdin,
  process.stdout
)
