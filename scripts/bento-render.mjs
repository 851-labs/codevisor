import { execFile } from "node:child_process"
import { access, copyFile, mkdir, mkdtemp, realpath, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { dirname, join, resolve } from "node:path"
import process from "node:process"
import { fileURLToPath } from "node:url"
import { parseArgs, promisify } from "node:util"

import { prepareSimulator } from "./bento-simulator.mjs"
import { developmentLayout } from "./dev-layout.mjs"
import { isPortAvailable } from "./dev-shared.mjs"
import { run } from "./screenshots-lib.mjs"

const usage = `Usage: bun run bento:render [--output directory] [--cards mcp-machines,accounts,…] [--skip-build]

Renders the landing page's feature cards from the Debug macOS app's real views with
fixture data, as <card>-<light|dark>@2x.png. The app runs headless in its own process
with in-memory state; it never touches a running Codevisor. inspector-window is cropped from the
main window, captured by screenshots:macos:direct --inspector. ghostty-terminal runs a real
"bun run dev" for a throwaway Vite project in tmp/bento-terminal, in a local shell that only
the screenshot app sees. simulator-pane boots a throwaway iPhone simulator, opens the emojis demo
page in Safari, screenshots it, and deletes the simulator before the app renders the pane.`

const root = await realpath(fileURLToPath(new URL("..", import.meta.url)))
const { values: options } = parseArgs({
  options: {
    output: { type: "string", default: "tmp/bento-shots" },
    cards: { type: "string" },
    "skip-build": { type: "boolean", default: false },
    help: { type: "boolean", default: false }
  }
})
if (options.help) {
  console.log(usage)
  process.exit(0)
}

const execute = promisify(execFile)
const terminalCard = "ghostty-terminal"
const simulatorCard = "simulator-pane"
const terminalHome = join(root, "tmp/bento-terminal/home")
const terminalPort = 3000
const windowCards = new Set(["inspector-window"])
const selectedCards = options.cards?.split(",")
const appCards = selectedCards?.filter((card) => !windowCards.has(card))

if (!options["skip-build"]) await run("bun", ["scripts/build-native.mjs", "macos"], { cwd: root })
if (appCards === undefined || appCards.length > 0) {
  const showsTerminal = appCards === undefined || appCards.includes(terminalCard)
  const showsSimulator = appCards === undefined || appCards.includes(simulatorCard)
  const scratchTemp = await mkdtemp(join(tmpdir(), "codevisor-bento-tmp-"))
  let simulator
  try {
    let terminal = {}
    if (showsTerminal) terminal = await prepareTerminalHome()
    if (showsSimulator) simulator = await prepareSimulator(root)
    await run(appExecutable(), ["-AppleLocale", "en_US@hours=h23"], {
      cwd: root,
      env: {
        ...renderEnvironment(),
        ...terminal,
        ...simulator?.environment,
        TMPDIR: scratchTemp
      }
    })
  } finally {
    if (showsTerminal) await execute("pkill", ["-f", terminalHome]).catch(() => {})
    if (simulator !== undefined) await rm(simulator.scratch, { recursive: true, force: true })
    await rm(scratchTemp, { recursive: true, force: true })
  }
}

async function prepareTerminalHome() {
  if (!(await isPortAvailable(terminalPort)))
    throw new Error(
      `The ghostty-terminal card shows Vite on localhost:${terminalPort}; free that port and render again`
    )
  const project = join(terminalHome, "emojis")
  await mkdir(project, { recursive: true })
  await writeFile(
    join(project, "package.json"),
    `${JSON.stringify(
      {
        name: "emojis",
        private: true,
        type: "module",
        scripts: { dev: "vite" }
      },
      null,
      2
    )}\n`
  )
  await writeFile(
    join(project, "vite.config.js"),
    `export default { clearScreen: false, server: { port: ${terminalPort}, strictPort: true } }\n`
  )
  await writeFile(
    join(project, "index.html"),
    "<!doctype html>\n<title>emojis</title>\n<h1>Every emoji, in your tone.</h1>\n"
  )
  const installed = await access(join(project, "node_modules/vite")).then(
    () => true,
    () => false
  )
  if (!installed) await execute("bun", ["add", "--dev", "vite"], { cwd: project })
  const bun = (await execute("which", ["bun"])).stdout.trim()
  return {
    CODEVISOR_BENTO_TERMINAL_HOME: terminalHome,
    CODEVISOR_BENTO_TERMINAL_PATH: `${dirname(bun)}:/usr/bin:/bin`
  }
}
if (selectedCards === undefined || selectedCards.includes("inspector-window")) {
  await renderInspectorWindow()
}

async function renderInspectorWindow() {
  const scratch = await mkdtemp(join(tmpdir(), "codevisor-bento-window-"))
  try {
    await run(
      "bun",
      ["scripts/screenshots-macos-direct.mjs", "--inspector", "--skip-build", "--output", scratch],
      { cwd: root }
    )
    await mkdir(resolve(root, options.output), { recursive: true })
    for (const appearance of ["light", "dark"]) {
      const name = `inspector-window-${appearance}@2x.png`
      const output = resolve(root, options.output, name)
      await copyFile(join(scratch, "macos-inspector", appearance, name), output)
      console.log(output)
    }
  } finally {
    await rm(scratch, { recursive: true, force: true })
  }
}

function appExecutable() {
  const products = join(developmentLayout(root).build.macos.derivedData, "Build/Products/Debug")
  return join(products, "Codevisor.app/Contents/MacOS/Codevisor")
}

function renderEnvironment() {
  return {
    ...process.env,
    CODEVISOR_BENTO_RENDER: resolve(root, options.output),
    CODEVISOR_DEMO_REPO: root,
    ...(appCards === undefined ? {} : { CODEVISOR_BENTO_CARDS: appCards.join(",") })
  }
}
