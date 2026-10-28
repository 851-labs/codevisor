import { spawn } from "node:child_process"
import { chmod, mkdtemp, readFile, rm, writeFile } from "node:fs/promises"
import { tmpdir } from "node:os"
import { join } from "node:path"

import { afterEach, describe, expect, it } from "vitest"

import { imageSetupScript, imageToolsScript } from "./image-setup.js"
import type { ExecResult } from "./provider.js"

const release = imageSetupScript({ app: { bundleName: "Codevisor.app" } })
const tools = imageToolsScript([
  "npm install -g @openai/codex",
  "curl -fsSL https://example.test/install | bash"
])

const development = imageSetupScript({
  app: {
    bundleName: "Codevisor (dev).app",
    development: { instanceId: "dev-sandbox", serverPort: 49361 }
  },
  installUrl: "http://192.168.1.2:4000/install.sh",
  installEnvironment: { CODEVISOR_VERSION: "dev" }
})

describe("macOS image setup script", () => {
  it("installs the app and the standalone server, and keeps the agent CLIs in their own layer", () => {
    expect(release).toContain("app='/Applications/Codevisor.app'")
    expect(release).toContain(
      '[ -d "$app" ] || { echo "error: $app was not copied into the VM" >&2; exit 1; }'
    )
    expect(release).toContain(
      'curl -fsSL \'https://www.codevisor.dev/install.sh\' -o "$installer"\nCODEVISOR_NO_SETUP=1 CODEVISOR_NO_SERVICE=1 CODEVISOR_INSTALL_SERVER=1 sh "$installer"'
    )
    expect(tools).toContain(
      "/bin/zsh -lc 'curl -fsSL https://example.test/install | bash' </dev/null || echo 'warning: curl -fsSL https://example.test/install | bash failed; the agent installs on first use instead'"
    )
    expect(release).not.toContain("npm install")
    expect(tools).not.toContain("/Applications")
    expect(development).toContain(
      "CODEVISOR_INSTALL_SERVER=1 CODEVISOR_VERSION='dev' sh \"$installer\""
    )
  })

  it("grants screen recording and input control to the app's signing identity, not a path", () => {
    expect(release).toContain('codesign -d -r- "$app"')
    expect(release).toContain("csreq -r- -b")
    for (const service of ["ScreenCapture", "Accessibility", "PostEvent", "ListenEvent"]) {
      expect(release).toContain(`kTCCService${service}`)
    }
    expect(release).toContain(
      `tcc_write sudo "$tcc_db" "insert or replace into access (service, client, client_type, auth_value, auth_reason, auth_version, csreq, flags) values ('$service', '$bundle_id', 0, 2, 4, 1, X'$csreq_hex', 0)"`
    )
  })

  it("opens the app whenever the VM starts and approves screen capture so macOS never asks", () => {
    expect(release).toContain(
      `printf '#!/bin/sh\\nexec /usr/bin/open %s -a %s\\n' "" "'$app'" > "$launcher"`
    )
    expect(release).toContain(
      'defaults write "$bundle_id" CodevisorUsesStandaloneServer -bool true'
    )
    expect(release).toContain("killall -9 replayd")
    expect(release).toContain(
      "<key>kScreenCapturePrivacyHintDate</key><date>2100-01-01T00:00:00Z</date>"
    )
    expect(release.trimEnd().endsWith("step 'The macOS image is ready'")).toBe(true)
  })

  it("answers the local network prompts once so every VM made from the image inherits them", () => {
    expect(release).toContain(
      'tcc_write env "$HOME/Library/Application Support/com.apple.TCC/TCC.db" "insert or replace into access'
    )
    expect(release).toContain(
      "'kTCCServiceAppleEvents', '$agent', 1, 2, 4, 1, 0, 'com.apple.systemevents', 0"
    )
    expect(release).toContain('type: "primeLocalNetwork"')
    expect(release).toContain('socket.send(Buffer.alloc(12), 5353, "224.0.0.251"')
    expect(release).toContain('click button "Allow" of alertWindow')
    expect(release).toContain(`"$(basename "$app" .app)"`)
  })

  it("launches a development build against the VM's own server and data", () => {
    expect(development).toContain(
      '"--env CODEVISOR_DEV_INSTANCE_ID=dev-sandbox --env CODEVISOR_DEV_PORT=49361 --env CODEVISOR_DEV_DATA_DIR=$HOME/.codevisor/data"'
    )
  })
})

describe("TCC database writes in the macOS image setup script", () => {
  const dirs: string[] = []

  afterEach(async () => {
    await Promise.all(dirs.splice(0).map((dir) => rm(dir, { recursive: true, force: true })))
  })

  const sqliteFailing = async (failures: number, error: string) => {
    const dir = await mkdtemp(join(tmpdir(), "codevisor-image-tcc-"))
    dirs.push(dir)
    const log = join(dir, "calls.log")
    await stub(dir, "sudo", `echo sudo >> '${log}'\nexec "$@"`)
    await stub(dir, "sleep", `echo "sleep $*" >> '${log}'`)
    await stub(
      dir,
      "sqlite3",
      [
        `echo "sqlite3 $*" >> '${log}'`,
        `count=$(grep -c '^sqlite3 ' '${log}')`,
        `[ "$count" -gt ${failures} ] && exit 0`,
        `echo '${error}' >&2`,
        "exit 1"
      ].join("\n")
    )
    const run = shell(
      [tccWriteFunction, 'tcc_write sudo /TCC.db "insert into access"', "echo granted"].join("\n"),
      dir
    )
    return { run, calls: async () => (await readFile(log, "utf8")).trimEnd().split("\n") }
  }

  it("waits out tccd's lock with a busy timeout and retries until the grant is written", async () => {
    const { run, calls } = await sqliteFailing(2, "Error: stepping, database is locked (5)")

    const result = await run

    expect(result).toEqual({ exitCode: 0, stdout: "granted\n", stderr: "" })
    const attempt = ["sudo", "sqlite3 -cmd .timeout 30000 /TCC.db insert into access"]
    expect(await calls()).toEqual([...attempt, "sleep 2", ...attempt, "sleep 2", ...attempt])
  })

  it("stops the image build with a clear message when the database stays locked", async () => {
    const { run, calls } = await sqliteFailing(5, "Error: stepping, database is locked (5)")

    const result = await run

    expect(result).toEqual({
      exitCode: 1,
      stdout: "",
      stderr:
        "error: /TCC.db was still locked after 5 tries of 30 s each, so macOS permissions were not granted\n"
    })
    expect((await calls()).filter((call) => call.startsWith("sqlite3"))).toHaveLength(5)
  })

  it("fails at once with sqlite's own error when the database is not locked", async () => {
    const { run, calls } = await sqliteFailing(1, "Error: no such table: access")

    const result = await run

    expect(result).toEqual({
      exitCode: 1,
      stdout: "",
      stderr: "error: Error: no such table: access\n"
    })
    expect(await calls()).toEqual([
      "sudo",
      "sqlite3 -cmd .timeout 30000 /TCC.db insert into access"
    ])
  })
})

const tccWriteFunction = /^tcc_write\(\) \{\n[\s\S]*?\n\}$/m.exec(release)?.[0] ?? ""

const stub = async (dir: string, name: string, body: string): Promise<void> => {
  const path = join(dir, name)
  await writeFile(path, `#!/bin/sh\n${body}\n`)
  await chmod(path, 0o755)
}

const shell = (script: string, bin: string): Promise<ExecResult> =>
  new Promise((resolve, reject) => {
    const child = spawn("/bin/sh", ["-c", `set -eu\n${script}`], {
      env: { PATH: `${bin}:/usr/bin:/bin` }
    })
    const output = { stdout: "", stderr: "" }
    child.stdout.setEncoding("utf8").on("data", (chunk: string) => {
      output.stdout += chunk
    })
    child.stderr.setEncoding("utf8").on("data", (chunk: string) => {
      output.stderr += chunk
    })
    child.on("error", reject)
    child.on("close", (code) => {
      resolve({ exitCode: code ?? -1, ...output })
    })
  })
