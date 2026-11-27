import assert from "node:assert/strict"
import { readFileSync } from "node:fs"
import { join } from "node:path"
import test, { describe } from "node:test"

import { install } from "./install-test-support.mjs"

const withDesktops = [
  'case "$*" in',
  '  "desktop setup --help"*) printf "USAGE\\n  codevisor desktop setup [flags]\\n" ;;',
  '  *) printf "codevisor 0.1.99\\n" ;;',
  "esac"
].join("\n")
const withoutDesktops = 'printf "USAGE\\n  codevisor <subcommand> [flags]\\n"'
const quiet = { CODEVISOR_NO_SERVICE: "1" }
const config = "data/screen-sharing.json"
const desktopLines = (result) => result.stdout.split("\n").filter((line) => /desktop/i.test(line))
const lastLine = (result) => result.stdout.trimEnd().split("\n").at(-1)

describe("install.sh and the Linux desktop", { concurrency: true }, () => {
  test("a fresh install on Linux ends by saying how to add a desktop", async (t) => {
    const result = await install(t, { cli: withDesktops, env: quiet })
    assert.equal(result.status, 0, result.stderr)
    assert.match(lastLine(result), /==>.* Add a desktop: codevisor desktop setup$/)
    assert.equal(desktopLines(result).length, 1)
  })

  test("a root install for the codevisor account words the line for that account", async (t) => {
    const result = await install(t, { cli: withDesktops, uid: 0, env: quiet })
    assert.equal(result.status, 0, result.stderr)
    assert.match(lastLine(result), /Add a desktop: su - codevisor -c 'codevisor desktop setup'$/)
  })

  test("installing over a desktop that Codevisor set up says nothing about desktops", async (t) => {
    const ours = JSON.stringify({
      vnc: { socket: "/run/user/1000/d.sock" },
      service: "systemd-user"
    })
    const result = await install(t, { cli: withDesktops, env: quiet, files: { [config]: ours } })
    assert.equal(result.status, 0, result.stderr)
    assert.deepEqual(desktopLines(result), [])
  })

  test("a desktop config that setup didn't write still gets the line, since setup can replace it", async (t) => {
    const older = JSON.stringify({ vnc: { host: "127.0.0.1", port: 5901 } })
    const result = await install(t, { cli: withDesktops, env: quiet, files: { [config]: older } })
    assert.match(lastLine(result), /Add a desktop: codevisor desktop setup$/)
  })

  test("a config that only mentions the word service isn't taken for a desktop setup made", async (t) => {
    const theirs = JSON.stringify({ vnc: { socket: "/tmp/x.sock", name: 'my "service" box' } })
    const result = await install(t, { cli: withDesktops, env: quiet, files: { [config]: theirs } })
    assert.match(lastLine(result), /Add a desktop: codevisor desktop setup$/)
  })

  test("after a No to the question in codevisor setup, installing again doesn't bring it up", async (t) => {
    const files = { "data/desktop-declined": "\n" }
    const result = await install(t, { cli: withDesktops, env: quiet, files })
    assert.equal(result.status, 0, result.stderr)
    assert.deepEqual(desktopLines(result), [])
  })

  test("a setup that failed in an earlier run doesn't hide the line from an install without a terminal", async (t) => {
    const files = { "data/desktop-setup-failed": "\n" }
    const result = await install(t, { cli: withDesktops, env: quiet, files })
    assert.match(lastLine(result), /Add a desktop: codevisor desktop setup$/)
  })

  test("a server release from before the desktop command isn't told about it", async (t) => {
    const result = await install(t, { cli: withoutDesktops, env: quiet })
    assert.equal(result.status, 0, result.stderr)
    assert.deepEqual(desktopLines(result), [])
  })

  test("asked for a desktop (adding a machine with one), the installer sets it up instead of the hint", async (t) => {
    const cli = [
      'printf "%s\\n" "$*" >> "$TEST_ROOT/cli.log"',
      'case "$*" in "desktop setup --help"*) printf "  codevisor desktop setup [flags]\\n" ;; esac'
    ].join("\n")
    const result = await install(t, { cli, env: { ...quiet, CODEVISOR_DESKTOP: "1" } })
    assert.equal(result.status, 0, result.stderr)
    assert.deepEqual(readFileSync(join(result.root, "cli.log"), "utf8").trim().split("\n"), [
      "desktop setup --help",
      "start",
      "desktop setup --yes"
    ])
    assert.match(result.stdout, /Setting up a desktop/)
    assert.doesNotMatch(result.stdout, /Add a desktop/)
  })

  test("asked for a desktop where one is set up, the installer still runs setup, which reports it running", async (t) => {
    const ours = JSON.stringify({
      vnc: { socket: "/run/user/1000/d.sock" },
      service: "systemd-user"
    })
    const cli = [
      'case "$*" in',
      '  "desktop setup --help"*) printf "  codevisor desktop setup [flags]\\n" ;;',
      '  "desktop setup --yes"*) printf "==> The desktop is already running. Open it from this machine in Codevisor.\\n" ;;',
      "esac"
    ].join("\n")
    const result = await install(t, {
      cli,
      env: { ...quiet, CODEVISOR_DESKTOP: "1" },
      files: { [config]: ours }
    })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /The desktop is already running/)
    assert.doesNotMatch(result.stdout, /Add a desktop/)
  })

  test("a desktop setup that fails doesn't fail the install it was asked with", async (t) => {
    const cli = [
      'case "$*" in',
      '  "desktop setup --help"*) printf "  codevisor desktop setup [flags]\\n" ;;',
      '  "desktop setup --yes"*) exit 1 ;;',
      "esac"
    ].join("\n")
    const result = await install(t, { cli, env: { ...quiet, CODEVISOR_DESKTOP: "1" } })
    assert.equal(result.status, 0, result.stderr)
    assert.match(
      lastLine(result),
      /The desktop wasn't set up\. Try again with: codevisor desktop setup$/
    )
  })

  test("asked for a desktop on a release that has none, the installer says so and finishes", async (t) => {
    const result = await install(t, {
      cli: withoutDesktops,
      env: { ...quiet, CODEVISOR_DESKTOP: "1" }
    })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /can't set up a desktop yet/)
    assert.doesNotMatch(result.stdout, /Setting up a desktop/)
  })

  test("asked for a desktop on a Mac, the installer does nothing about it", async (t) => {
    const result = await install(t, {
      cli: withDesktops,
      platform: "Darwin",
      architecture: "x86_64",
      env: { CODEVISOR_INSTALL_SERVER: "1", CODEVISOR_DESKTOP: "1" }
    })
    assert.equal(result.status, 0, result.stderr)
    assert.deepEqual(desktopLines(result), [])
  })

  test("installing the server on a Mac says nothing about desktops", async (t) => {
    const result = await install(t, {
      cli: withDesktops,
      platform: "Darwin",
      architecture: "x86_64",
      env: { CODEVISOR_INSTALL_SERVER: "1" }
    })
    assert.equal(result.status, 0, result.stderr)
    assert.match(result.stdout, /Installing codevisor-server 0\.1\.99 \(darwin-x64\)/)
    assert.deepEqual(desktopLines(result), [])
  })
})
