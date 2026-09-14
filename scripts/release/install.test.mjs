import assert from "node:assert/strict"
import { execFileSync, spawnSync } from "node:child_process"
import { createHash } from "node:crypto"
import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs"
import { tmpdir } from "node:os"
import { join } from "node:path"
import test from "node:test"

const installer = readFileSync(new URL("../../apps/www/public/install.sh", import.meta.url), "utf8")
const stableURL = "https://updates.codevisor.dev/server/stable.json"
const githubLatestURL = "https://api.github.com/repos/851-labs/codevisor/releases/latest"
const downloadBase = "https://github.com/851-labs/codevisor/releases/download"

// Exercise the piped shell script, real archive extraction, and CLI links.
// Only network responses, platform detection, and service commands are faked.
const install = (t, options = {}) => {
  const root = mkdtempSync(join(tmpdir(), "codevisor-installer-"))
  t.after(() => rmSync(root, { recursive: true, force: true }))
  const bin = join(root, "commands")
  const runtime = join(root, "runtime")
  const archiveRoot = join(root, "archive")
  for (const directory of [bin, runtime, join(archiveRoot, "bin")]) {
    mkdirSync(directory, { recursive: true })
  }
  writeFileSync(join(runtime, "old-runtime"), "existing installation")
  const version = options.expectedVersion ?? "0.1.99"
  const architecture = options.architecture ?? "x86_64"
  const target = architecture === "aarch64" ? "linux-arm64" : "linux-x64"
  for (const name of ["codevisor", "codevisor-server", "codevisor-terminal-proxy"]) {
    writeFileSync(join(archiveRoot, "bin", name), `#!/bin/sh\nprintf 'codevisor ${version}\\n'\n`, {
      mode: 0o755
    })
  }
  const archive = join(root, "server.tar.gz")
  execFileSync("tar", ["-czf", archive, "-C", archiveRoot, "."])
  const digest = createHash("sha256").update(readFileSync(archive)).digest("hex")
  const checksum = join(root, "checksum")
  writeFileSync(checksum, `${digest}  codevisor-server-${target}.tar.gz\n`)
  const archiveURL = `${downloadBase}/v${version}/codevisor-server-${target}.tar.gz`
  const responses = {
    [stableURL]: {
      body: options.manifest ?? JSON.stringify({ version: "0.1.99", buildNumber: 422 }, null, 2),
      status: options.manifestStatus ?? 0
    },
    [githubLatestURL]: { body: JSON.stringify({ tag_name: "v0.1.94" }) },
    [archiveURL]: { file: archive },
    [`${archiveURL}.sha256`]: { file: checksum },
    [`${downloadBase}/v${version}/Codevisor-arm64.dmg`]: { body: "fixture disk image" }
  }
  writeFileSync(join(root, "responses.json"), JSON.stringify(responses))
  const requests = join(root, "requests.jsonl")
  const services = join(root, "services.log")
  writeFileSync(requests, "")
  writeFileSync(services, "")
  const commands = {
    uname:
      'case "$1" in -s) printf "%s\\n" "$TEST_PLATFORM";; -m) printf "%s\\n" "$TEST_ARCH";; *) exit 1;; esac',
    id: 'printf "%s\\n" "$TEST_UID"',
    systemctl: 'printf "%s\\n" "$*" >> "$TEST_SERVICES"',
    // Stop the macOS path before it can touch /Applications or a running app.
    hdiutil: "exit 71",
    sha256sum: `exec '${process.execPath.replaceAll("'", "'\\''")}' "$TEST_ROOT/sha256.mjs" "$@"`
  }
  for (const [command, body] of Object.entries(commands)) {
    writeFileSync(join(bin, command), `#!/bin/sh\nset -eu\n${body}\n`, { mode: 0o755 })
  }
  writeFileSync(
    join(root, "sha256.mjs"),
    `import { readFileSync } from 'node:fs';
import { createHash } from 'node:crypto';
console.log(createHash('sha256').update(readFileSync(process.argv[2])).digest('hex'));`
  )
  writeFileSync(
    join(bin, "curl"),
    `#!${process.execPath}
import { appendFileSync, readFileSync, writeFileSync } from 'node:fs';
const args = process.argv.slice(2);
const url = args.at(-1);
appendFileSync(process.env.TEST_REQUESTS, JSON.stringify({ url, args }) + '\\n');
const response = JSON.parse(readFileSync(process.env.TEST_ROOT + '/responses.json'))[url];
if (!response) { console.error('Unexpected URL: ' + url); process.exit(22); }
if (response.status) process.exit(response.status);
const body = response.file ? readFileSync(response.file) : response.body;
const output = args.indexOf('-o');
if (output === -1) process.stdout.write(body);
else writeFileSync(args[output + 1], body);
`,
    { mode: 0o755 }
  )
  const result = spawnSync("/bin/sh", [], {
    input: installer,
    encoding: "utf8",
    env: {
      PATH: `${bin}:/usr/bin:/bin`,
      HOME: root,
      USER: "installer-test",
      LC_ALL: "C",
      TMPDIR: root,
      CODEVISOR_INSTALL_DIR: runtime,
      CODEVISOR_BIN_DIR: join(root, "bin"),
      CODEVISOR_DATA_DIR: options.defaultDataDir ? undefined : join(root, "data"),
      CODEVISOR_NO_SETUP: "1",
      TEST_ROOT: root,
      TEST_REQUESTS: requests,
      TEST_SERVICES: services,
      TEST_PLATFORM: options.platform ?? "Linux",
      TEST_ARCH: architecture,
      TEST_UID: String(options.uid ?? 1000),
      ...options.env
    }
  })
  assert.ifError(result.error)
  return {
    ...result,
    root,
    runtime,
    requests: readFileSync(requests, "utf8").trim().split("\n").filter(Boolean).map(JSON.parse),
    services: readFileSync(services, "utf8")
  }
}

for (const uid of [0, 1000]) {
  test(`Linux uid ${uid} uses the same canonical home data directory`, (t) => {
    const result = install(t, { uid, defaultDataDir: true, env: { CODEVISOR_NO_SERVICE: "1" } })
    assert.equal(result.status, 0, result.stderr)
    assert.ok(existsSync(join(result.root, ".codevisor", "data")))
    assert.ok(existsSync(join(result.root, ".codevisor", "logs")))
    assert.equal(result.services, "")
  })
}

for (const architecture of ["x86_64", "aarch64"]) {
  test(`Linux ${architecture} installs current stable despite a stale GitHub latest pointer`, (t) => {
    const result = install(t, { architecture })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /Installing codevisor-server 0\.1\.99/)
    assert.match(result.stdout, /Checksum verified/)
    assert.equal(existsSync(join(result.runtime, "old-runtime")), false)
    for (const command of ["codevisor", "codevisor-server", "codevisor-terminal-proxy"]) {
      assert.equal(
        execFileSync(join(result.root, "bin", command), { encoding: "utf8" }),
        "codevisor 0.1.99\n"
      )
    }
    assert.deepEqual(
      result.requests.map(({ url }) => url),
      [
        stableURL,
        `${downloadBase}/v0.1.99/codevisor-server-linux-${architecture === "aarch64" ? "arm64" : "x64"}.tar.gz`,
        `${downloadBase}/v0.1.99/codevisor-server-linux-${architecture === "aarch64" ? "arm64" : "x64"}.tar.gz.sha256`
      ]
    )
    assert.ok(result.requests[0].args.includes("Cache-Control: no-cache"))
    assert.match(result.services, /--user restart codevisor-server\.service/)
  })
}

for (const manifest of [
  '{"targets":{},"version":"0.1.99","buildNumber":422}',
  '{\n  "version":\n    "v0.1.99"\n}'
]) {
  test(`accepts stable manifest formatting: ${JSON.stringify(manifest)}`, (t) => {
    const result = install(t, { manifest })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /Installing codevisor-server 0\.1\.99/)
  })
}

for (const [name, options] of [
  ["unavailable feed", { manifestStatus: 22 }],
  ["missing version", { manifest: '{"buildNumber":422}' }],
  ["empty response", { manifest: "" }],
  ["HTML error", { manifest: "<html>Unavailable</html>" }],
  ["invalid version", { manifest: '{"version":"0.1"}' }],
  ["alpha version", { manifest: '{"version":"0.1.100-alpha.493"}' }]
]) {
  test(`${name} fails before changing the installation without falling back to GitHub`, (t) => {
    const result = install(t, options)
    assert.equal(result.status, 1)
    assert.match(result.stderr, /stable.*https:\/\/updates\.codevisor\.dev\/server\/stable\.json/)
    assert.match(result.stderr, /CODEVISOR_VERSION/)
    assert.deepEqual(
      result.requests.map(({ url }) => url),
      [stableURL]
    )
    assert.equal(existsSync(join(result.runtime, "old-runtime")), true)
    assert.equal(result.services, "")
  })
}

for (const [name, env, expectedVersion] of [
  ["explicit stable", { CODEVISOR_VERSION: "0.1.98" }, "0.1.98"],
  [
    "explicit alpha with v prefix",
    { CODEVISOR_VERSION: "v0.1.100-alpha.493" },
    "0.1.100-alpha.493"
  ],
  ["legacy pin", { HERDMAN_VERSION: "v0.1.97" }, "0.1.97"],
  [
    "modern pin takes precedence",
    { CODEVISOR_VERSION: "0.1.98", HERDMAN_VERSION: "0.1.97" },
    "0.1.98"
  ]
]) {
  test(`${name} bypasses the stable feed, even when it is unavailable`, (t) => {
    const result = install(t, { env, expectedVersion, manifestStatus: 22 })
    assert.equal(result.status, 0, result.stderr)
    assert.ok(result.stdout.includes(`Installing codevisor-server ${expectedVersion}`))
    assert.equal(result.requests.length, 2)
    assert.ok(
      result.requests.every(({ url }) => url.startsWith(`${downloadBase}/v${expectedVersion}/`))
    )
  })
}

test("macOS uses the current stable version for its architecture-specific app download", (t) => {
  const result = install(t, { platform: "Darwin", architecture: "arm64" })
  assert.equal(result.status, 71, result.stderr)
  assert.match(result.stdout, /Installing Codevisor 0\.1\.99 for macOS/)
  assert.deepEqual(
    result.requests.map(({ url }) => url),
    [stableURL, `${downloadBase}/v0.1.99/Codevisor-arm64.dmg`]
  )
})
